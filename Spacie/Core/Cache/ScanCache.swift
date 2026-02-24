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
/// │  Magic:          4 bytes  "SPCE"           │
/// │  Version:        UInt32   (format version) │
/// │  Node count:     UInt32                    │
/// │  Pool size:      UInt32   (bytes)          │
/// │  Scan date:      Float64  (timeInterval    │
/// │                  Since1970)                │
/// │  Root path       UInt32 (len) + UTF-8 bytes│
/// │  scanComplete:   UInt8   (0/1)             │
/// │  lastPhase:      UInt8   (1=Ph1, 2=Ph2)   │
/// │  lastEventId:    UInt64  (FSEvents ID)     │
/// │  scannedDirCount:UInt32                    │
/// │  [scannedDirs]:  [UInt64] (FNV-1a hashes) │
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
    private static let formatVersion: UInt32 = 2

    /// Public accessor for the current format version.
    ///
    /// Used by ``ScanCacheWAL`` to embed the base format version in WAL headers,
    /// ensuring WAL files are only replayed against compatible cache blobs.
    static let currentFormatVersion: UInt32 = formatVersion

    /// Header size: magic(4) + version(4) + nodeCount(4) + poolSize(4) + scanDate(8) = 24
    /// Plus variable-length root path and scan metadata fields.
    private static let fixedHeaderSize = 24

    /// Size of scan metadata fields (excluding variable-length scannedDirPaths):
    /// scanComplete(1) + lastPhase(1) + lastEventId(8) + scannedDirCount(4) = 14
    private static let scanMetadataFixedSize = 14

    /// Cache directory name within ~/Library/Caches/
    private static let cacheDirectoryName = "com.spacie.app"

    // MARK: - Cache Info

    /// Metadata about a cached volume, readable without fully deserializing the node array.
    struct CacheInfo: Sendable {
        /// Volume identifier (derived from cache filename).
        let volumeId: String
        /// Human-readable volume name (derived from the cached root path).
        let volumeName: String
        /// Size of the main cache blob file in bytes.
        let cacheSize: UInt64
        /// Size of the WAL companion file in bytes.
        let walSize: UInt64
        /// Date of the last completed scan stored in the cache header.
        let lastScanDate: Date?
        /// Number of serialized ``FileNode`` entries in the cache.
        let nodeCount: Int
        /// Whether the cached scan completed all phases successfully.
        let isComplete: Bool
    }

    // MARK: - Static Cache Directory

    /// Returns the cache directory URL, creating it if necessary.
    private static var cacheDirectoryURL: URL {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = cachesDirectory
            .appendingPathComponent(cacheDirectoryName, isDirectory: true)

        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )

        return cacheDir
    }

    /// Returns the cache file URL for a given volume ID.
    ///
    /// - Parameter volumeId: The unique identifier (UUID) of the volume.
    /// - Returns: The URL pointing to the `.cache` file on disk.
    private static func cacheFileURL(for volumeId: String) -> URL {
        let sanitizedId = volumeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return cacheDirectoryURL.appendingPathComponent("\(sanitizedId).cache")
    }

    /// Scans the cache directory for all `.cache` files and returns their volume IDs.
    ///
    /// Volume IDs are extracted by reversing the filename sanitization
    /// (stripping the `.cache` extension). The returned order is undefined.
    ///
    /// - Returns: An array of volume ID strings for which cache files exist.
    static func allCachedVolumeIds() -> [String] {
        let cacheDir = cacheDirectoryURL
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents
            .filter { $0.pathExtension == "cache" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }

    /// Reads cache metadata (header only) without deserializing the full node array.
    ///
    /// Opens the cache file and reads only the fixed and variable-length header fields
    /// (magic, version, nodeCount, scanDate, rootPath, scanComplete). Also reads
    /// file sizes for the blob and WAL companion. This is significantly cheaper than
    /// ``load()`` since no nodes or string pool data are parsed.
    ///
    /// - Parameter volumeId: The unique identifier (UUID) of the volume.
    /// - Returns: A ``CacheInfo`` instance, or `nil` if the cache file doesn't exist
    ///   or has an incompatible format version.
    static func cacheInfo(for volumeId: String) -> CacheInfo? {
        let url = cacheFileURL(for: volumeId)
        let filePath = url.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: filePath) else {
            return nil
        }

        // Get blob file size
        guard let blobAttrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let blobSize = blobAttrs[.size] as? UInt64 else {
            return nil
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        // Validate minimum size (fixed header)
        guard data.count >= fixedHeaderSize else {
            return nil
        }

        var offset = 0

        // Magic bytes
        let fileMagic = Array(data[offset..<offset + 4])
        guard fileMagic == magic else { return nil }
        offset += 4

        // Format version
        let version: UInt32 = data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        guard version == formatVersion else { return nil }
        offset += 4

        // Node count
        let nodeCount: Int = data.withUnsafeBytes { buffer in
            Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
        offset += 4

        // Pool size (skip, not needed for metadata)
        offset += 4

        // Scan date
        let timestamp: Float64 = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: Float64.self)
        }
        offset += 8

        // Root path (length-prefixed)
        guard offset + 4 <= data.count else { return nil }
        let rootPathLength: Int = data.withUnsafeBytes { buffer in
            Int(UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }
        offset += 4

        guard offset + rootPathLength <= data.count else { return nil }
        let rootPathData = data[offset..<offset + rootPathLength]
        let rootPath = String(data: rootPathData, encoding: .utf8) ?? "/"
        offset += rootPathLength

        // Scan metadata: scanComplete flag
        var isComplete = false
        if offset + 1 <= data.count {
            let scanCompleteByte: UInt8 = data.withUnsafeBytes { buffer in
                buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
            }
            isComplete = scanCompleteByte != 0
        }

        // Derive volume name from root path
        let volumeName: String
        if rootPath == "/" {
            volumeName = "Macintosh HD"
        } else {
            volumeName = (rootPath as NSString).lastPathComponent
        }

        // Get WAL file size
        let walURL = ScanCacheWAL.walFileURL(for: volumeId)
        let walPath = walURL.path(percentEncoded: false)
        let walSize: UInt64
        if let walAttrs = try? FileManager.default.attributesOfItem(atPath: walPath),
           let ws = walAttrs[.size] as? UInt64 {
            walSize = ws
        } else {
            walSize = 0
        }

        let scanDate = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil

        return CacheInfo(
            volumeId: volumeId,
            volumeName: volumeName,
            cacheSize: blobSize,
            walSize: walSize,
            lastScanDate: scanDate,
            nodeCount: nodeCount,
            isComplete: isComplete
        )
    }

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

    /// Whether the cached scan completed all phases successfully.
    /// `false` indicates the scan was interrupted (crash, user cancel).
    private(set) var scanComplete: Bool = false

    /// The last scan phase that completed writing to the cache.
    /// 0 = no phase completed, 1 = Phase 1 (shallow), 2 = Phase 2 (deep).
    private(set) var lastPhase: UInt8 = 0

    /// The FSEvents stream event ID at the time the cache was written.
    /// Used for crash recovery to replay events since the last checkpoint.
    private(set) var lastEventId: UInt64 = 0

    /// FNV-1a hashes of directory paths that were fully scanned.
    /// Used for crash recovery to determine which directories still need scanning.
    private(set) var scannedDirPaths: Set<UInt64> = []

    /// The FSEvents monitor for detecting file system changes.
    private var monitor: FSEventsMonitor?

    /// Lock for thread-safe access to mutable state.
    private let lock = NSLock()

    /// The WAL (Write-Ahead Log) companion for incremental cache updates.
    ///
    /// Lazily initialized on first access. Stores per-directory rescan results
    /// as append-only binary entries that can be replayed on top of the base blob.
    private(set) lazy var wal: ScanCacheWAL = ScanCacheWAL(volumeId: volumeId)

    /// The file URL for the WAL companion file.
    var walFileURL: URL { ScanCacheWAL.walFileURL(for: volumeId) }

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
    /// Creates the cache directory if it doesn't exist. Delegates to the
    /// static ``cacheFileURL(for:)`` method using this instance's ``volumeId``.
    private var cacheFileURL: URL {
        Self.cacheFileURL(for: volumeId)
    }

    /// Returns the full path to the directory size cache companion file for this volume.
    ///
    /// Uses the same directory as ``cacheFileURL`` but with a `.dirsizes` extension.
    /// This companion file stores a JSON-encoded `[String: UInt64]` mapping directory
    /// paths to their scanned byte sizes, used by ``SmartScanPrioritizer`` to order
    /// Tier 2 directories by historical size on subsequent scans.
    private var dirSizeCacheURL: URL {
        let cacheURL = cacheFileURL
        return cacheURL.deletingPathExtension().appendingPathExtension("dirsizes")
    }

    // MARK: - Save

    /// Saves a ``FileTree`` to the persistent cache.
    ///
    /// Serializes the tree's nodes and string pool into the binary format
    /// and writes it atomically to disk. Includes scan metadata for
    /// crash recovery and incremental rescan support.
    ///
    /// - Parameters:
    ///   - tree: The file tree to cache.
    ///   - scanComplete: Whether all scan phases completed successfully.
    ///   - lastPhase: The last scan phase that completed (1 = shallow, 2 = deep).
    ///   - lastEventId: The FSEvents stream event ID at the time of writing.
    ///   - scannedDirPaths: FNV-1a hashes of fully scanned directory paths.
    /// - Throws: File I/O errors if the cache cannot be written.
    func save(
        tree: FileTree,
        scanComplete: Bool = true,
        lastPhase: UInt8 = 2,
        lastEventId: UInt64 = 0,
        scannedDirPaths: Set<UInt64> = []
    ) throws {
        let nodes = tree.serializedNodes
        let poolData = tree.stringPool.serializedData
        let rootPath = tree.rootPath
        let scanDate = Date()

        var data = Data()

        // Estimate total size for pre-allocation
        let rootPathUTF8 = rootPath.utf8
        let estimatedSize = Self.fixedHeaderSize
            + 4 + rootPathUTF8.count // root path length prefix + bytes
            + Self.scanMetadataFixedSize // scan metadata fixed fields
            + scannedDirPaths.count * 8 // scanned dir path hashes
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

        // --- Scan metadata ---
        // Scan complete flag
        appendUInt8(&data, scanComplete ? 1 : 0)

        // Last completed phase
        appendUInt8(&data, lastPhase)

        // Last FSEvents stream event ID
        appendUInt64(&data, lastEventId)

        // Scanned directory path hashes
        appendUInt32(&data, UInt32(scannedDirPaths.count))
        for hash in scannedDirPaths {
            appendUInt64(&data, hash)
        }

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
        self.dirtyPaths.removeAll()
        monitoredPath = rootPath
        self.scanComplete = scanComplete
        self.lastPhase = lastPhase
        self.lastEventId = lastEventId
        self.scannedDirPaths = scannedDirPaths
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

        // --- Scan metadata ---
        // Read new fields gracefully: if file is too short (e.g., truncated v2 cache),
        // treat as incomplete scan with default metadata.
        var loadedScanComplete: Bool = false
        var loadedLastPhase: UInt8 = 0
        var loadedLastEventId: UInt64 = 0
        var loadedScannedDirPaths: Set<UInt64> = []

        if offset + Self.scanMetadataFixedSize <= data.count {
            // scanComplete
            loadedScanComplete = readUInt8(data, at: offset) != 0
            offset += 1

            // lastPhase
            loadedLastPhase = readUInt8(data, at: offset)
            offset += 1

            // lastEventId
            loadedLastEventId = readUInt64(data, at: offset)
            offset += 8

            // scannedDirCount + hashes
            let scannedDirCount = Int(readUInt32(data, at: offset))
            offset += 4

            let scannedDirBytesNeeded = scannedDirCount * 8
            if offset + scannedDirBytesNeeded <= data.count {
                for _ in 0..<scannedDirCount {
                    let hash = readUInt64(data, at: offset)
                    loadedScannedDirPaths.insert(hash)
                    offset += 8
                }
            }
            // If scannedDirPaths are truncated, keep whatever we read and continue
        }

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
        scanComplete = loadedScanComplete
        lastPhase = loadedLastPhase
        lastEventId = loadedLastEventId
        scannedDirPaths = loadedScannedDirPaths
        lock.unlock()

        return tree
    }

    // MARK: - Directory Size Cache

    /// Saves a dictionary of directory path to scanned byte size for Smart Scan prioritization.
    ///
    /// The data is JSON-encoded and written atomically to the companion `.dirsizes` file.
    /// Used after a successful deep scan so that subsequent scans can prioritize Tier 2
    /// directories by their last known size.
    ///
    /// - Parameter sizes: Dictionary mapping absolute directory paths to their total logical byte size.
    /// - Throws: Encoding or file I/O errors.
    func saveDirectorySizes(_ sizes: [String: UInt64]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sizes)
        try data.write(to: dirSizeCacheURL, options: [.atomic])
    }

    /// Loads previously cached directory sizes for Smart Scan prioritization.
    ///
    /// - Returns: A dictionary mapping directory paths to their scanned byte sizes,
    ///   or `nil` if no companion cache exists or if it cannot be decoded.
    func loadDirectorySizes() -> [String: UInt64]? {
        let url = dirSizeCacheURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        return try? JSONDecoder().decode([String: UInt64].self, from: data)
    }

    // MARK: - Invalidation

    /// Deletes the cache file, WAL file, companion directory size cache,
    /// and resets all state.
    ///
    /// Called when the format version mismatches, data is corrupted,
    /// or the user explicitly requests a full rescan.
    func invalidate() {
        let url = cacheFileURL
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: dirSizeCacheURL)
        wal.deleteWAL()

        lock.lock()
        lastScanDate = nil
        isDirty = false
        dirtyPaths.removeAll()
        scanComplete = false
        lastPhase = 0
        lastEventId = 0
        scannedDirPaths.removeAll()
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

    // MARK: - WAL Compaction

    /// Returns `true` when the WAL file size exceeds 10% of the blob file size.
    ///
    /// This heuristic triggers compaction to prevent unbounded WAL growth.
    /// If the blob file does not exist, returns `false` (no compaction target).
    func shouldCompact() -> Bool {
        let walSize = wal.fileSize
        guard walSize > 0 else { return false }

        let blobURL = cacheFileURL
        guard let blobAttrs = try? FileManager.default.attributesOfItem(
            atPath: blobURL.path(percentEncoded: false)
        ),
        let blobSize = blobAttrs[.size] as? UInt64,
        blobSize > 0 else {
            return false
        }

        // WAL exceeds 10% of the blob size
        return walSize > blobSize / 10
    }

    /// Rewrites the blob from the current tree state and deletes the WAL.
    ///
    /// Compaction folds all WAL entries into a fresh blob by serializing the
    /// in-memory ``FileTree`` (which should already have WAL patches applied).
    /// After the blob is written atomically, the WAL file is deleted.
    ///
    /// - Parameters:
    ///   - tree: The file tree with all WAL patches applied.
    ///   - lastEventId: The FSEvents stream event ID to store in the new blob header.
    /// - Throws: File I/O errors if the blob cannot be written.
    func compactWAL(tree: FileTree, lastEventId: UInt64 = 0) throws {
        // Rewrite the full blob from current tree state
        try save(
            tree: tree,
            scanComplete: true,
            lastPhase: 2,
            lastEventId: lastEventId,
            scannedDirPaths: scannedDirPaths
        )

        // Delete the WAL now that all its entries are folded into the blob
        wal.deleteWAL()
    }

    // MARK: - Binary Helpers

    /// Appends a UInt8 value to a Data buffer.
    private func appendUInt8(_ data: inout Data, _ value: UInt8) {
        data.append(value)
    }

    /// Appends a UInt32 value to a Data buffer in little-endian byte order.
    private func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Appends a UInt64 value to a Data buffer in little-endian byte order.
    private func appendUInt64(_ data: inout Data, _ value: UInt64) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// Reads a UInt8 value from Data at the specified byte offset.
    private func readUInt8(_ data: Data, at offset: Int) -> UInt8 {
        data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
        }
    }

    /// Reads a UInt32 value from Data at the specified byte offset (little-endian).
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { buffer in
            UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    /// Reads a UInt64 value from Data at the specified byte offset (little-endian).
    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { buffer in
            UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}
