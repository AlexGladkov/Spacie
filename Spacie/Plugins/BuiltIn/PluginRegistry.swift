import Foundation

// MARK: - PluginManager

/// Central registry for all cleanup category plugins.
/// Holds built-in and user-registered categories for smart cleanup scanning.
@Observable
final class PluginManager: @unchecked Sendable {

    // MARK: Singleton

    static let shared = PluginManager()

    // MARK: State

    private(set) var categories: [any CleanupCategory] = []

    // MARK: Init

    private init() {}

    // MARK: Registration

    /// Registers a single cleanup category.
    func register(_ category: any CleanupCategory) {
        // Prevent duplicate registration
        guard !categories.contains(where: { $0.id == category.id }) else { return }
        categories.append(category)
    }

    /// Returns all registered categories.
    var allCategories: [any CleanupCategory] {
        categories
    }

    /// Registers all 13 built-in cleanup categories.
    func registerBuiltIn() {
        register(XcodeDerivedDataCategory())
        register(XcodeArchivesCategory())
        register(XcodeDeviceSupportCategory())
        register(HomebrewCacheCategory())
        register(NpmCacheCategory())
        register(NodeModulesCategory())
        register(DockerCategory())
        register(GradleCacheCategory())
        register(SystemLogsCategory())
        register(CrashReportsCategory())
        register(IOSBackupsCategory())
        register(DownloadsOldCategory())
        register(TrashCategory())
    }

    /// Removes all registered categories.
    func removeAll() {
        categories.removeAll()
    }

    /// Scans all registered categories and returns results sorted by size.
    func scanAll() async -> [CategoryResult] {
        await withTaskGroup(of: CategoryResult?.self) { group in
            for category in categories {
                group.addTask {
                    await self.scanCategory(category)
                }
            }

            var results: [CategoryResult] = []
            for await result in group {
                if let result {
                    results.append(result)
                }
            }

            return results.sorted { $0.totalSize > $1.totalSize }
        }
    }

    // MARK: Private

    private func scanCategory(_ category: any CleanupCategory) async -> CategoryResult? {
        let fm = FileManager.default
        var totalSize: UInt64 = 0
        var allItems: [CleanupItem] = []
        var isAvailable = false

        for searchPath in category.searchPaths {
            let expandedURL = searchPath.expandedURL

            guard fm.fileExists(atPath: expandedURL.path) else { continue }
            isAvailable = true

            do {
                let items = try await category.detailedItems(at: expandedURL)

                // Apply minAge filter if set
                let filteredItems: [CleanupItem]
                if let minAge = searchPath.minAge {
                    let cutoff = Date().addingTimeInterval(-minAge)
                    filteredItems = items.filter { item in
                        guard let date = item.modificationDate else { return true }
                        return date < cutoff
                    }
                } else {
                    filteredItems = items
                }

                allItems.append(contentsOf: filteredItems)
                totalSize += filteredItems.reduce(0) { $0 + $1.size }
            } catch {
                // If detailedItems fails, try to compute directory size directly
                if let dirSize = try? fm.allocatedSizeOfDirectory(at: expandedURL) {
                    totalSize += dirSize
                    allItems.append(CleanupItem(
                        url: expandedURL,
                        name: expandedURL.lastPathComponent,
                        size: dirSize,
                        modificationDate: nil,
                        isDirectory: true
                    ))
                }
            }
        }

        return CategoryResult(
            id: category.id,
            category: category,
            totalSize: totalSize,
            itemCount: allItems.count,
            items: allItems,
            isAvailable: isAvailable
        )
    }
}
