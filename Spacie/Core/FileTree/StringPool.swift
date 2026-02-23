import Foundation

// MARK: - StringPool

/// A contiguous memory pool for interning file name strings.
///
/// All file names in the ``FileTree`` are stored in a single `Data` buffer
/// rather than as individual Swift `String` heap allocations. Each name is
/// referenced by an `(offset, length)` pair stored in the corresponding
/// ``FileNode``. This dramatically reduces memory overhead and allocation
/// pressure when dealing with millions of nodes.
///
/// ## Memory Layout
/// ```
/// ┌─────────┬──────────┬──────────┬──────────┬─────┐
/// │ "Users" │ "Desktop"│ "file.tx"│ ".DS_Sto"│ ... │
/// │  5 bytes│  7 bytes │  7 bytes │  9 bytes │     │
/// └─────────┴──────────┴──────────┴──────────┴─────┘
///  offset=0   offset=5   offset=12  offset=19
/// ```
///
/// ## Thread Safety
/// `StringPool` is a value type. The ``FileTree`` actor ensures exclusive
/// access during the build phase and safe concurrent reads after completion.
struct StringPool: Sendable {

    // MARK: - Properties

    /// The underlying contiguous byte buffer holding all interned strings as UTF-8.
    private(set) var storage: Data

    /// The current write position (next available offset in the buffer).
    private(set) var currentOffset: UInt32

    // MARK: - Initialization

    /// Creates a new string pool with the specified initial capacity.
    ///
    /// - Parameter initialCapacity: Pre-allocated buffer size in bytes.
    ///   Defaults to 1 MB, which is sufficient for approximately 50,000
    ///   average file names before needing to grow.
    init(initialCapacity: Int = 1_048_576) {
        self.storage = Data()
        self.storage.reserveCapacity(initialCapacity)
        self.currentOffset = 0
    }

    // MARK: - Interning

    /// Appends a string to the pool and returns its location descriptor.
    ///
    /// The string is stored as raw UTF-8 bytes without a null terminator.
    /// The caller is responsible for tracking the returned offset and length
    /// to later retrieve the string via ``getString(offset:length:)``.
    ///
    /// - Parameter string: The string to intern.
    /// - Returns: A tuple of `(offset, length)` identifying the string's
    ///   position within the pool. `length` is capped at `UInt16.max` (65535 bytes);
    ///   strings exceeding this are silently truncated.
    @discardableResult
    mutating func append(_ string: String) -> (offset: UInt32, length: UInt16) {
        let utf8 = string.utf8
        let byteCount = min(utf8.count, Int(UInt16.max))
        let offset = currentOffset

        storage.append(contentsOf: utf8.prefix(byteCount))
        currentOffset &+= UInt32(byteCount)

        return (offset: offset, length: UInt16(byteCount))
    }

    // MARK: - Retrieval

    /// Retrieves a string from the pool by its offset and length.
    ///
    /// - Parameters:
    ///   - offset: The byte offset into the pool where the string begins.
    ///   - length: The number of bytes to read.
    /// - Returns: The reconstructed `String`, or `"?"` if the UTF-8 data is invalid.
    func getString(offset: UInt32, length: UInt16) -> String {
        let start = Int(offset)
        let count = Int(length)

        guard count > 0, start + count <= storage.count else {
            return ""
        }

        return storage.withUnsafeBytes { buffer in
            let bytes = buffer.baseAddress!.advanced(by: start)
                .assumingMemoryBound(to: UInt8.self)
            return String(
                bytes: UnsafeBufferPointer(start: bytes, count: count),
                encoding: .utf8
            ) ?? "?"
        }
    }

    // MARK: - Metrics

    /// Total number of bytes currently used in the pool.
    var byteCount: Int {
        Int(currentOffset)
    }

    /// Total allocated bytes in the underlying buffer (same as ``byteCount``).
    var capacity: Int {
        storage.count
    }

    // MARK: - Serialization

    /// Returns the raw bytes of the string pool for binary serialization.
    var serializedData: Data {
        storage
    }

    /// Creates a string pool from previously serialized data.
    ///
    /// - Parameter data: Raw bytes previously obtained from ``serializedData``.
    init(deserializedFrom data: Data) {
        self.storage = data
        self.currentOffset = UInt32(data.count)
    }

    // MARK: - Maintenance

    /// Removes all interned strings and resets the pool.
    mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        currentOffset = 0
    }

    /// Ensures the pool has at least the specified additional capacity available.
    ///
    /// - Parameter additionalBytes: Number of additional bytes to reserve.
    mutating func reserveAdditionalCapacity(_ additionalBytes: Int) {
        let needed = Int(currentOffset) + additionalBytes
        if needed > storage.count {
            storage.reserveCapacity(needed)
        }
    }
}
