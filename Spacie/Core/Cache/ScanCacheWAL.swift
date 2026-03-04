import Foundation

// MARK: - WALEntry

/// A single entry in the WAL (Write-Ahead Log) representing a rescanned directory.
///
/// Each entry captures the complete state of a directory's children at a point in time,
/// including serialized ``FileNode`` structs and the corresponding ``StringPool`` data.
/// The `dirPath` field is **not** stored in the WAL binary format; it is resolved by the
/// caller from the `dirPathHash` for convenience.
struct WALEntry: Sendable {
    /// FNV-1a hash of the directory's full path.
    let dirPathHash: UInt64
    /// Resolved directory path (for convenience; NOT stored in the WAL binary format).
    let dirPath: String
    /// Unix timestamp (seconds since epoch) when the entry was written.
    let timestamp: UInt64
    /// Serialized ``FileNode`` structs for the directory's children.
    let nodes: [FileNode]
    /// Raw bytes of the ``StringPool`` data for the nodes in this entry.
    let stringPoolData: Data
}

// MARK: - ScanCacheWAL

/// Append-only Write-Ahead Log for incremental scan cache updates.
///
/// The WAL stores per-directory rescan results as binary entries that can be replayed
/// on top of a base ``ScanCache`` blob. This allows frequent, lightweight writes
/// (e.g., after incremental rescans or deletions) without rewriting the entire blob.
///
/// ## Binary Format
/// ```
/// +--------------------------------------------+
/// | Header (16 bytes)                          |
/// |  Magic:             [UInt8] x 4 = "SWAL"  |
/// |  Version:           UInt32 = 1             |
/// |  BaseFormatVersion: UInt32                 |
/// |  EntryCount:        UInt32                 |
/// +--------------------------------------------+
/// | Entry 0 (variable length)                  |
/// |  dir_path_hash:     UInt64                 |
/// |  timestamp:         UInt64                 |
/// |  node_count:        UInt32                 |
/// |  string_pool_size:  UInt32                 |
/// |  nodes:             [UInt8] x (node_count  |
/// |                      * MemoryLayout        |
/// |                      <FileNode>.stride)    |
/// |  string_pool_data:  [UInt8] x              |
/// |                      string_pool_size      |
/// +--------------------------------------------+
/// | Entry 1 ...                                |
/// +--------------------------------------------+
/// ```
///
/// ## Truncation Resilience
/// If the application crashes mid-write, ``readAll()`` detects the incomplete trailing
/// entry (insufficient remaining bytes) and returns only the successfully written entries.
///
/// ## Thread Safety
/// All file operations are serialized with `NSLock`, matching the ``ScanCache`` pattern.
final class ScanCacheWAL: @unchecked Sendable {

    // MARK: - Constants

    /// Magic bytes identifying a Spacie WAL file.
    private static let magic: [UInt8] = [0x53, 0x57, 0x41, 0x4C] // "SWAL"

    /// Current WAL format version.
    private static let walVersion: UInt32 = 1

    /// Total header size in bytes: magic(4) + version(4) + baseFormatVersion(4) + entryCount(4).
    private static let headerSize = 16

    /// Fixed portion of each entry before variable-length payload:
    /// dirPathHash(8) + timestamp(8) + nodeCount(4) + stringPoolSize(4) = 24.
    private static let entryFixedSize = 24

    /// Cache directory name within ~/Library/Caches/.
    private static let cacheDirectoryName = "com.spacie.app"

    // MARK: - Properties

    /// The volume ID this WAL is associated with.
    let volumeId: String

    /// Lock for thread-safe access to file operations.
    private let lock = NSLock()

    /// Cached open file handle — avoids open/close syscall overhead on each append.
    private var _fileHandle: FileHandle?

    /// In-memory entry count; avoids a read-modify-write round trip on each append.
    private var _entryCount: UInt32 = 0

    // MARK: - Initialization

    /// Creates a WAL instance for the specified volume.
    ///
    /// - Parameter volumeId: The unique identifier (UUID) of the volume.
    init(volumeId: String) {
        self.volumeId = volumeId
    }

    // MARK: - File Path

    /// Returns the file URL for the WAL companion file for the given volume.
    ///
    /// The WAL file lives alongside the main cache blob in
    /// `~/Library/Caches/com.spacie.app/<volume-uuid>.wal`.
    ///
    /// - Parameter volumeId: The unique identifier (UUID) of the volume.
    /// - Returns: The URL to the WAL file on disk.
    /// Cache directory URL (pure computation, no side effects).
    /// The directory is created lazily before the first write via ``ensureWALDirectoryExists()``.
    private static let walDirectoryURL: URL = {
        let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return cachesDirectory.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }()

    /// Creates the WAL directory if it does not already exist. Call before writes.
    private static func ensureWALDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: walDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    static func walFileURL(for volumeId: String) -> URL {
        // Sanitize volume ID for use as a filename
        let sanitizedId = volumeId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        return walDirectoryURL.appendingPathComponent("\(sanitizedId).wal")
    }

    /// The file URL for this instance's WAL file.
    private var fileURL: URL {
        Self.walFileURL(for: volumeId)
    }

    // MARK: - Append

    /// Appends a single entry to the WAL file.
    ///
    /// Uses a cached `FileHandle` to eliminate open/close syscall overhead on
    /// each call. The entry count in the header is updated in-memory and
    /// written back after each append so it stays consistent even after a crash.
    ///
    /// - Parameters:
    ///   - dirPathHash: FNV-1a hash of the directory's full path.
    ///   - nodes: The ``FileNode`` structs to serialize for this directory.
    ///   - stringPoolData: Raw bytes of the ``StringPool`` for these nodes.
    /// - Throws: File I/O errors if the WAL cannot be written.
    func append(dirPathHash: UInt64, nodes: [FileNode], stringPoolData: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        let handle = try openOrCreateHandleLocked()

        // Seek to end and write entry
        handle.seekToEndOfFile()
        let entryData = buildEntryData(
            dirPathHash: dirPathHash,
            nodes: nodes,
            stringPoolData: stringPoolData
        )
        handle.write(entryData)

        // Update in-memory count and write back to header (offset 12)
        _entryCount += 1
        handle.seek(toFileOffset: 12)
        var countLE = _entryCount.littleEndian
        let countBytes = withUnsafeBytes(of: &countLE) { Data($0) }
        handle.write(countBytes)
    }

    /// Opens or returns the cached `FileHandle` for appending.
    ///
    /// Creates the WAL file with a fresh header if it does not yet exist.
    /// The caller **must** hold `lock` before calling this method.
    ///
    /// - Returns: An open `FileHandle` positioned for updates.
    /// - Throws: File I/O errors if the handle cannot be opened.
    private func openOrCreateHandleLocked() throws -> FileHandle {
        if let handle = _fileHandle { return handle }

        // Ensure the directory exists before creating the WAL file
        Self.ensureWALDirectoryExists()

        let url = fileURL
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let headerData = buildHeader(entryCount: 0)
            try headerData.write(to: url, options: [])
            _entryCount = 0
        } else {
            // Read existing entry count so _entryCount stays accurate
            if let existingData = try? Data(contentsOf: url, options: [.mappedIfSafe]),
               existingData.count >= Self.headerSize {
                _entryCount = existingData.withUnsafeBytes { buffer in
                    UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                }
            }
        }

        let handle = try FileHandle(forUpdating: url)
        _fileHandle = handle
        return handle
    }

    // MARK: - Read All

    /// Reads all valid entries from the WAL file.
    ///
    /// Iterates through the WAL sequentially, deserializing each entry.
    /// If a partial (truncated) entry is encountered at the tail of the file
    /// (e.g., from a crash during write), it is silently skipped and only
    /// the successfully written entries are returned.
    ///
    /// - Returns: An array of ``WALEntry`` values. The `dirPath` field is set
    ///   to an empty string since the WAL does not store resolved paths.
    /// - Throws: File I/O errors if the WAL cannot be read.
    func readAll() throws -> [WALEntry] {
        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])

        // Validate header
        guard data.count >= Self.headerSize else {
            return []
        }

        // Check magic
        let magic = Array(data[0..<4])
        guard magic == Self.magic else {
            return []
        }

        // Check WAL version
        let version = readUInt32(data, at: 4)
        guard version == Self.walVersion else {
            return []
        }

        // Read declared entry count (informational; we rely on byte-level validation)
        let _declaredCount = readUInt32(data, at: 12)

        var entries: [WALEntry] = []
        entries.reserveCapacity(Int(_declaredCount))

        var offset = Self.headerSize

        while offset < data.count {
            // Check if enough bytes remain for the fixed portion of an entry
            guard offset + Self.entryFixedSize <= data.count else {
                // Truncated entry: not enough bytes for even the fixed header.
                break
            }

            let dirPathHash = readUInt64(data, at: offset)
            offset += 8

            let timestamp = readUInt64(data, at: offset)
            offset += 8

            let nodeCount = Int(readUInt32(data, at: offset))
            offset += 4

            let stringPoolSize = Int(readUInt32(data, at: offset))
            offset += 4

            // Calculate expected payload size
            let nodeStride = MemoryLayout<FileNode>.stride
            let nodeBytes = nodeCount * nodeStride
            let totalPayloadSize = nodeBytes + stringPoolSize

            // Validate that enough bytes remain for the full payload
            guard offset + totalPayloadSize <= data.count else {
                // Truncated entry: payload is incomplete. Discard this entry.
                break
            }

            // Deserialize nodes
            let nodes: [FileNode] = data.withUnsafeBytes { buffer in
                let nodePtr = buffer.baseAddress!.advanced(by: offset)
                    .assumingMemoryBound(to: FileNode.self)
                return Array(UnsafeBufferPointer(start: nodePtr, count: nodeCount))
            }
            offset += nodeBytes

            // Extract string pool data
            let poolData = Data(data[offset..<offset + stringPoolSize])
            offset += stringPoolSize

            let entry = WALEntry(
                dirPathHash: dirPathHash,
                dirPath: "", // Resolved by caller
                timestamp: timestamp,
                nodes: nodes,
                stringPoolData: poolData
            )
            entries.append(entry)
        }

        return entries
    }

    // MARK: - Validation

    /// Checks whether the WAL file exists, has a valid header, and matches
    /// the expected base format version.
    ///
    /// - Parameter baseFormatVersion: The ``ScanCache`` format version to validate against.
    /// - Returns: `true` if the WAL is present and compatible; `false` otherwise.
    func isValid(baseFormatVersion: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return false
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return false
        }

        guard data.count >= Self.headerSize else {
            return false
        }

        // Check magic
        let magic = Array(data[0..<4])
        guard magic == Self.magic else {
            return false
        }

        // Check WAL version
        let version = readUInt32(data, at: 4)
        guard version == Self.walVersion else {
            return false
        }

        // Check base format version compatibility
        let storedBaseVersion = readUInt32(data, at: 8)
        return storedBaseVersion == baseFormatVersion

    }

    // MARK: - Deletion

    /// Deletes the WAL file from disk.
    ///
    /// Closes and releases the cached `FileHandle` before removing the file.
    /// Silently ignores errors if the file does not exist.
    func deleteWAL() {
        lock.lock()
        defer { lock.unlock() }

        try? _fileHandle?.close()
        _fileHandle = nil
        _entryCount = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - File Size

    /// Current size of the WAL file in bytes.
    ///
    /// Returns `0` if the file does not exist or its size cannot be determined.
    var fileSize: UInt64 {
        lock.lock()
        defer { lock.unlock() }

        let url = fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        ) else {
            return 0
        }
        return (attrs[.size] as? UInt64) ?? 0
    }

    // MARK: - FNV-1a Hash

    /// Computes the FNV-1a 64-bit hash of a string.
    ///
    /// Uses the standard FNV-1a algorithm with the official 64-bit offset basis
    /// and prime. The string is hashed as its UTF-8 byte representation.
    ///
    /// - Parameter string: The string to hash.
    /// - Returns: The 64-bit FNV-1a hash value.
    static func fnv1aHash(_ string: String) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x00000100000001B3

        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return hash
    }

    // MARK: - Private Helpers

    /// Builds the 16-byte WAL header.
    ///
    /// - Parameter entryCount: The initial entry count to write.
    /// - Returns: A `Data` instance containing the serialized header.
    private func buildHeader(entryCount: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(Self.headerSize)

        // Magic bytes
        data.append(contentsOf: Self.magic)

        // WAL version
        appendUInt32(&data, Self.walVersion)

        // Base format version (must match ScanCache.formatVersion)
        appendUInt32(&data, ScanCache.currentFormatVersion)

        // Entry count
        appendUInt32(&data, entryCount)

        return data
    }

    /// Builds the binary data for a single WAL entry.
    ///
    /// - Parameters:
    ///   - dirPathHash: FNV-1a hash of the directory's full path.
    ///   - nodes: The ``FileNode`` structs to serialize.
    ///   - stringPoolData: Raw ``StringPool`` bytes for these nodes.
    /// - Returns: A `Data` instance containing the serialized entry.
    private func buildEntryData(
        dirPathHash: UInt64,
        nodes: [FileNode],
        stringPoolData: Data
    ) -> Data {
        let nodeStride = MemoryLayout<FileNode>.stride
        let estimatedSize = Self.entryFixedSize + nodes.count * nodeStride + stringPoolData.count

        var data = Data()
        data.reserveCapacity(estimatedSize)

        // dir_path_hash
        appendUInt64(&data, dirPathHash)

        // timestamp
        appendUInt64(&data, UInt64(Date().timeIntervalSince1970))

        // node_count
        appendUInt32(&data, UInt32(nodes.count))

        // string_pool_size
        appendUInt32(&data, UInt32(stringPoolData.count))

        // nodes (raw struct bytes)
        nodes.withUnsafeBufferPointer { buffer in
            let rawBuffer = UnsafeRawBufferPointer(buffer)
            data.append(contentsOf: rawBuffer)
        }

        // string_pool_data
        data.append(stringPoolData)

        return data
    }

    // MARK: - Binary Helpers

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
