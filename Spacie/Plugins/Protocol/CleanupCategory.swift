import SwiftUI

// MARK: - CleanupCategory Protocol

/// Protocol for defining smart cleanup categories.
/// Built-in and community plugins implement this to identify cleanable areas.
public protocol CleanupCategory: Identifiable, Sendable {
    var id: String { get }
    var name: LocalizedStringResource { get }
    var description: LocalizedStringResource { get }
    var icon: String { get } // SF Symbol name
    var searchPaths: [CleanupSearchPath] { get }

    /// Custom logic to determine if a specific item can be safely deleted.
    /// Default implementation returns true.
    func canSafelyDelete(item: URL) async -> Bool

    /// Returns detailed sub-items for display in the UI.
    /// For example, individual project folders inside DerivedData.
    func detailedItems(at path: URL) async throws -> [CleanupItem]
}

// Default implementations
public extension CleanupCategory {
    func canSafelyDelete(item: URL) async -> Bool {
        true
    }

    func detailedItems(at path: URL) async throws -> [CleanupItem] {
        // Collect URLs synchronously to avoid Swift 6 Sendable issues
        // with NSDirectoryEnumerator in async contexts.
        let urls = CleanupCategoryHelpers.collectURLs(at: path)

        var items: [CleanupItem] = []
        for url in urls {
            let resources = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            let size = UInt64(resources?.fileSize ?? 0)
            let isDir = resources?.isDirectory ?? false

            if isDir {
                // Calculate directory size
                let dirSize = try? FileManager.default.allocatedSizeOfDirectory(at: url)
                items.append(CleanupItem(
                    url: url,
                    name: url.lastPathComponent,
                    size: dirSize ?? size,
                    modificationDate: resources?.contentModificationDate,
                    isDirectory: true
                ))
            } else {
                items.append(CleanupItem(
                    url: url,
                    name: url.lastPathComponent,
                    size: size,
                    modificationDate: resources?.contentModificationDate,
                    isDirectory: false
                ))
            }
        }
        return items.sorted { $0.size > $1.size }
    }
}

// MARK: - CleanupSearchPath

public struct CleanupSearchPath: Sendable {
    public let path: String          // Absolute path or ~ for home
    public let glob: String?         // Optional glob pattern
    public let recursive: Bool       // Search recursively
    public let minAge: TimeInterval? // Minimum file age in seconds

    public init(path: String, glob: String? = nil, recursive: Bool = false, minAge: TimeInterval? = nil) {
        self.path = path
        self.glob = glob
        self.recursive = recursive
        self.minAge = minAge
    }

    public var expandedPath: String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    public var expandedURL: URL {
        URL(fileURLWithPath: expandedPath)
    }
}

// MARK: - CleanupItem

public struct CleanupItem: Identifiable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let size: UInt64
    public let modificationDate: Date?
    public let isDirectory: Bool

    public init(url: URL, name: String, size: UInt64, modificationDate: Date?, isDirectory: Bool) {
        self.id = url.path
        self.url = url
        self.name = name
        self.size = size
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
    }
}

// MARK: - CategoryResult

struct CategoryResult: Identifiable, Sendable {
    let id: String
    let category: any CleanupCategory
    let totalSize: UInt64
    let itemCount: Int
    let items: [CleanupItem]
    let isAvailable: Bool // false if path doesn't exist

    var displaySize: String { totalSize.formattedSize }
}

// MARK: - CleanupCategoryHelpers

/// Synchronous helpers to avoid using NSDirectoryEnumerator in async contexts.
enum CleanupCategoryHelpers {
    static func collectURLs(at path: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: path,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            urls.append(url)
        }
        return urls
    }
}

// MARK: - FileManager extension for directory size

extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var totalSize: UInt64 = 0
        guard let enumerator = self.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: []
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            totalSize += UInt64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileAllocatedSize ?? 0)
        }
        return totalSize
    }
}
