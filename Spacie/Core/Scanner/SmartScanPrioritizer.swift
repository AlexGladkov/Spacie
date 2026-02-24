import Foundation

// MARK: - SmartScanPrioritizer

/// Builds a prioritized directory queue for Smart Scan's Phase 2.
///
/// The queue is divided into two tiers:
/// - **Tier 1**: Known "heavy" directories from the active ``ScanProfile``.
///   These are scanned unconditionally and first.
/// - **Tier 2**: All remaining directories not covered by Tier 1,
///   sorted by cached size (descending) with entry count as fallback.
///
/// This ordering maximizes coverage growth per directory scanned,
/// allowing the scan to reach the coverage threshold faster.
struct SmartScanPrioritizer: Sendable {

    // MARK: - Queue Building

    /// Builds a prioritized scanning queue from the shallow tree and optional cached sizes.
    ///
    /// - Parameters:
    ///   - settings: The active Smart Scan settings (determines profile and paths).
    ///   - shallowTree: The Phase 1 shallow tree containing directory nodes with entry counts.
    ///   - cachedDirSizes: Optional dictionary of path-to-byte-size from a previous scan cache.
    /// - Returns: Ordered array of `(path, entryCount)` tuples, Tier 1 first, then Tier 2.
    static func buildPrioritizedQueue(
        settings: SmartScanSettings,
        shallowTree: FileTree,
        cachedDirSizes: [String: UInt64]?
    ) -> [(path: String, entryCount: UInt32)] {
        // Build a lookup from path -> (index, entryCount) for all directories in the shallow tree
        let allDirs = shallowTree.allDirectoriesByEntryCount()
        var dirsByPath: [String: (index: UInt32, entryCount: UInt32)] = [:]
        dirsByPath.reserveCapacity(allDirs.count)

        for dir in allDirs {
            let path = shallowTree.fullPath(of: dir.index)
            dirsByPath[path] = (dir.index, dir.entryCount)
        }

        // Tier 1: profile paths
        let tier1Paths = ScanProfile.tier1Paths(for: settings.profile)
        var tier1Set = Set<String>()
        var tier1Queue: [(path: String, entryCount: UInt32)] = []
        tier1Queue.reserveCapacity(tier1Paths.count)

        for path in tier1Paths {
            tier1Set.insert(path)
            if let entry = dirsByPath[path] {
                tier1Queue.append((path: path, entryCount: entry.entryCount))
            } else {
                // Synthetic entry for paths excluded from shallow tree
                // (e.g., in ScanExclusionManager.defaultPathPrefixes)
                tier1Queue.append((path: path, entryCount: 0))
            }
        }

        // Tier 2: remaining directories NOT in Tier 1 and NOT children of Tier 1 paths
        var tier2Queue: [(path: String, entryCount: UInt32, cachedSize: UInt64)] = []

        for (path, entry) in dirsByPath {
            guard !tier1Set.contains(path) else { continue }
            guard !isChildOfAny(path: path, parents: tier1Set) else { continue }

            let cachedSize = cachedDirSizes?[path] ?? 0
            tier2Queue.append((path: path, entryCount: entry.entryCount, cachedSize: cachedSize))
        }

        // Sort Tier 2: cached size descending, fallback to entry count descending
        tier2Queue.sort { lhs, rhs in
            if lhs.cachedSize != rhs.cachedSize {
                return lhs.cachedSize > rhs.cachedSize
            }
            return lhs.entryCount > rhs.entryCount
        }

        let tier2Result = tier2Queue.map { (path: $0.path, entryCount: $0.entryCount) }

        return tier1Queue + tier2Result
    }

    // MARK: - Skip Logic

    /// Determines whether a directory should be skipped because it (or a parent path)
    /// has already been scanned.
    ///
    /// - Parameters:
    ///   - dirPath: The absolute path of the directory to check.
    ///   - completedPaths: Set of paths that have already been deep-scanned.
    /// - Returns: `true` if the directory should be skipped.
    static func shouldSkipDirectory(
        _ dirPath: String,
        completedPaths: Set<String>
    ) -> Bool {
        // Skip if this exact path was already scanned
        if completedPaths.contains(dirPath) {
            return true
        }

        // Skip if a parent path was already scanned (this dir is a subtree of a completed scan)
        let dirWithSlash = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        for completed in completedPaths {
            let completedWithSlash = completed.hasSuffix("/") ? completed : completed + "/"
            if dirWithSlash.hasPrefix(completedWithSlash) {
                return true
            }
        }

        return false
    }

    // MARK: - Private Helpers

    /// Checks whether `path` is a child (descendant) of any path in the given set.
    private static func isChildOfAny(path: String, parents: Set<String>) -> Bool {
        let pathWithSlash = path.hasSuffix("/") ? path : path + "/"
        for parent in parents {
            let parentWithSlash = parent.hasSuffix("/") ? parent : parent + "/"
            if pathWithSlash.hasPrefix(parentWithSlash) {
                return true
            }
        }
        return false
    }
}
