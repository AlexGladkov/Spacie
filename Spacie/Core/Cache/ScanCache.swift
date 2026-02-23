import Foundation

// MARK: - ScanCache

/// Persistent scan cache with FSEvents-based incremental invalidation.
///
/// Serializes and deserializes a ``FileTree`` (including its ``StringPool``)
/// to a compact binary format stored in `~/Library/Caches/com.spacie.app/`.
/// After a successful scan, the tree is cached so subsequent launches can
/// display results instantly while monitoring for changes via FSEvents.
///
/// ## Binary Format
/// ```
/// ┌────────────────────────────────────────────┐
/// │ Header                                     │
/// │  Magic:       4 bytes  "SPCE"              │
/// │  Version:     UInt32   (format version)    │
/// │  Node count:  UInt32                       │
/// │  Pool size:   UInt32   (bytes)             │
/// │  Scan date:   Float64  (timeIntervalSince  │
/// │               1970)                        │
/// │  Root path    UInt32 (length) + UTF-8 bytes│
/// ├────────────────────────────────────────────┤
/// │ String pool:  [UInt8]  (raw UTF-8)         │
/// ├────────────────────────────────────────────┤
/// │ Nodes:        [FileNode] (raw structs)     │
/// └────────────────────────────────────────────┘
/// ```
///
/// ## Cache Invalidation
/// - FSEvents monitor detects changes and marks dirty paths.
/// - If the cache format version doesn't match, the cache is auto-deleted.
/// - After 24 hours, the UI suggests a rescan.
final class ScanCache: @unchecked Sendable {

    // MARK: - Constants

    /// Magic bytes identifying a Spacie cache file.
    private static let magic: [UInt8] = [0x53, 0x50, 0x43, 0x45] // "SPCE"

    /// Current binary format version. Increment on breaking changes.
    private static let formatVersion: UInt32 = 1

    /// Header size: magic(4) + version(4) + nodeCount(4) + poolSize(4) + scanDate(8) = 24
    /// Plus variable-length root path.
    private static let fixedHeaderSize = 24

    /// Cache directory name within ~/Library/Caches/
    private static let cacheDirectoryName = "com.spacie.app"

    // MARK: - Properties

    /// The volume ID this cache is associated with.
    let volumeId: String

    /// The root path being monitored for changes.
    private(set) var monitoredPath: String?

    /// Date of the last successful scan that was cached.
    private(set) var lastScanDate: Date?

    /// Whether FSEvents has detected changes since the cache was written.
    private(set) var isDirty: Bool = false

    /// Set of paths that have been modified since the cache was saved.
    /// Used for incremental rescan targeting.
    private(set) var dirtyPaths: Set<String> = []

    /// The FSEvents monitor for detecting file system changes.
    private var monitor: FSEventsMonitor?

    /// Lock for thread-safe access to mutable state.
    private let lock = NSLock()

    // MARK: - Initialization

    /// Creates a cache instance for the specified volume.
    ///
    /// - Parameter volumeId: The unique identifier (UUID) of the volume.
    init(volumeId: String) {
        self.volumeId = volumeId
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Cache File Path

    /// Returns the full path to the cache file for this volume.
    ///
    /// Creates the cache directory if it doesn't exist.
    private var cacheFileURL: URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = cachesDirectory
            .appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)

        // Ensure the directory exists
        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )

        // Sanitize volume ID for use as a filename
        let sanitizedId = volumeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        return cacheDir.appendingPathComponent("\(sanitizedId).cache")
    }

    // MARK: - Save

    /// Saves a ``FileTree`` to the persistent cache.
    ///
    /// Serializes the tree's nodes and string pool into the binary format
    /// and writes it atomically to disk.
    ///
    /// - Parameter tree: The file tree to cache.
    /// - Throws: File I/O errors if the cache cannot be written.
    func save(tree: FileTree) throws {
        let nodes = tree.serializedNodes
        let poolData = tree.stringPool.serializedData
        let rootPath = tree.rootPath
        let scanDate = Date()

        var data = Data()

        // Estimate total size for pre-allocation
        let rootPathUTF8 = rootPath.utf8
        let estimatedSize = Self.fixedHeaderSize
            + 4 + rootPathUTF8.count // root path length prefix + bytes
            + poolData.count
            + nodes.count * MemoryLayout<FileNode>.stride
        data.reserveCapacity(estimatedSize)

        // --- Header ---
        // Magic bytes
        data.append(contentsOf: Self.magic)

        // Format version
        appendUInt32(&data, Self.formatVersion)

        // Node count
        appendUInt32(&data, UInt32(nodes.count))

        // String pool size
        appendUInt32(&data, UInt32(poolData.count))

        // Scan date as TimeInterval (Float64)
        var timestamp = scanDate.timeIntervalSince1970
        withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }

        // Root path (length-prefixed)
        let rootPathBytes = Array(rootPathUTF8)
        appendUInt32(&data, UInt32(rootPathBytes.count))
        data.append(contentsOf: rootPathBytes)

        // --- String pool ---
        data.append(poolData)

        // --- Nodes ---
        nodes.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: rawBuffer)
        }

        // Write atomically
        try data.write(to: cacheFileURL, options: [.atomic])

        lock.lock()
        lastScanDate = scanDate
        isDirty = false
        dirtyPaths.removeAll()
        monitoredPath = rootPath
        lock.unlock()
    }

    // MARK: - Load

    /// Loads a ``FileTree`` from the persistent cache.
    ///
    /// Validates the magic bytes and format version before deserializing.
    /// Returns `nil` if the cache doesn't exist, is corrupted, or has a
    /// mismatched format version (auto-deleted in that case).
    ///
    /// - Returns: The deserialized ``FileTree``, or `nil` if unavailable.
    func load() -> FileTree? {
        let url = cacheFileURL

        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        // Validate minimum size (fixed header)
        guard data.count >= Self.fixedHeaderSize else {
            invalidate()
            return nil
        }

        var offset = 0

        // --- Magic bytes ---
        let magic = Array(data[offset..<offset + 4])
        guard magic == Self.magic else {
            invalidate()
            return nil
        }
        offset += 4

        // --- Format version ---
        let version = readUInt32(data, at: offset)
        guard version == Self.formatVersion else {
            // Version mismatch: delete stale cache
            invalidate()
            return nil
        }
        offset += 4

        // --- Node count ---
        let nodeCount = Int(readUInt32(data, at: offset))
        offset += 4

        // --- String pool size ---
        let poolSize = Int(readUInt32(data, at: offset))
        offset += 4

        // --- Scan date ---
        let timestamp: Float64 = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: Float64.self)
        }
        offset += 8

        // --- Root path ---
        guard offset + 4 <= data.count else {
            invalidate()
            return nil
        }
        let rootPathLength = Int(readUInt32(data, at: offset))
        offset += 4

        guard offset + rootPathLength <= data.count else {
            invalidate()
            return nil
        }
        let rootPathData = data[offset..<offset + rootPathLength]
        let rootPath = String(data: rootPathData, encoding: .utf8) ?? "/"
        offset += rootPathLength

        // --- String pool ---
        guard offset + poolSize <= data.count else {
            invalidate()
            return nil
        }
        let poolData = Data(data[offset..<offset + poolSize])
        offset += poolSize

        // --- Nodes ---
        let nodeStride = MemoryLayout<FileNode>.stride
        let expectedNodeBytes = nodeCount * nodeStride
        guard offset + expectedNodeBytes <= data.count else {
            invalidate()
            return nil
        }

        let nodes: [FileNode] = data.withUnsafeBytes { buffer in
            let nodePtr = buffer.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: FileNode.self)
            return Array(UnsafeBufferPointer(start: nodePtr, count: nodeCount))
        }

        let stringPool = StringPool(deserializedFrom: poolData)
        let tree = FileTree(
            deserializedNodes: nodes,
            stringPool: stringPool,
            rootPath: rootPath
        )

        lock.lock()
        lastScanDate = Date(timeIntervalSince1970: timestamp)
        monitoredPath = rootPath
        isDirty = false
        dirtyPaths.removeAll()
        lock.unlock()

        return tree
    }

    // MARK: - Invalidation

    /// Deletes the cache file and resets all state.
    ///
    /// Called when the format version mismatches, data is corrupted,
    /// or the user explicitly requests a full rescan.
    func invalidate() {
        let url = cacheFileURL
        try? FileManager.default.removeItem(at: url)

        lock.lock()
        lastScanDate = nil
        isDirty = false
        dirtyPaths.removeAll()
        lock.unlock()
    }

    /// Returns whether the cached data is considered stale.
    ///
    /// A cache is stale if it's older than the specified maximum age.
    ///
    /// - Parameter maxAge: Maximum acceptable cache age. Defaults to 24 hours.
    /// - Returns: `true` if the cache is older than `maxAge` or if no scan date is recorded.
    func isStale(maxAge: TimeInterval = 86400) -> Bool {
        lock.lock()
        let date = lastScanDate
        lock.unlock()

        guard let date else { return true }
        return Date().timeIntervalSince(date) > maxAge
    }

    // MARK: - FSEvents Monitoring

    /// Starts monitoring the cached path for file system changes.
    ///
    /// FSEvents notifications are used to track which paths have changed
    /// since the last scan, enabling incremental rescan of only dirty subtrees.
    ///
    /// - Parameter path: The root path to monitor. Typically the same path that was scanned.
    func startMonitoring(path: String) {
        lock.lock()
        monitoredPath = path
        lock.unlock()

        stopMonitoring()

        let newMonitor = FSEventsMonitor(path: path, latency: 2.0) { [weak self] events in
            self?.handleFSEvents(events)
        }
        newMonitor.start()

        lock.lock()
        monitor = newMonitor
        lock.unlock()
    }

    /// Stops monitoring file system changes.
    func stopMonitoring() {
        lock.lock()
        let currentMonitor = monitor
        monitor = nil
        lock.unlock()

        currentMonitor?.stop()
    }

    /// Processes incoming FSEvents and updates the dirty state.
    private func handleFSEvents(_ events: [FSEventsMonitor.Event]) {
        lock.lock()
        defer { lock.unlock() }

        for event in events {
            // If we get a mustScanSubDirs event, the FSEvents buffer overflowed
            // and we must treat the entire tree as dirty.
            if event.mustScanSubDirs {
                isDirty = true
                dirtyPaths.removeAll()
                // Insert the monitored root to signal "rescan everything"
                if let root = monitoredPath {
                    dirtyPaths.insert(root)
                }
                return
            }

            // Track the specific changed path
            if event.isCreated || event.isRemoved || event.isRenamed || event.isModified {
                isDirty = true
                dirtyPaths.insert(event.path)
            }
        }
    }

    /// Returns the current set of dirty paths and clears them.
    ///
    /// This is used by the incremental rescan logic to determine which
    /// subtrees need to be re-scanned.
    ///
    /// - Returns: The set of paths that changed since the last scan.
    func consumeDirtyPaths() -> Set<String> {
        lock.lock()
        let paths = dirtyPaths
        dirtyPaths.removeAll()
        isDirty = false
        lock.unlock()
        return paths
    }

    /// Returns whether a cache file exists for this volume.
    var cacheExists: Bool {
        FileManager.default.fileExists(atPath: cacheFileURL.path(percentEncoded: false))
    }

    // MARK: - Binary Helpers

    /// Appends a UInt32 value to a Data buffer in little-endian byte order.
    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Reads a UInt32 value from Data at the specified byte offset (little-endian).
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }
}
