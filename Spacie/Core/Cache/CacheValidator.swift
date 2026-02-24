import Foundation

// MARK: - CacheValidator

/// Validates cached directory metadata against the live filesystem.
///
/// Compares the `dirMtime` (directory modification time) stored in each
/// ``FileNode`` against the current `st_mtimespec.tv_sec` obtained via
/// `lstat()`. Any mismatch indicates the directory's contents have changed
/// since the cache was written, making it "dirty" and requiring a rescan.
///
/// ## Two-Pass Approach
/// 1. **Priority pass (depth 0-2):** Validates top-level directories first,
///    providing near-instant feedback (~100-500 dirs, <0.1s). This covers
///    the most visible parts of the tree and catches major structural changes
///    (e.g., new user directories, deleted top-level folders).
///
/// 2. **Background pass (depth > 2):** Validates all remaining directories
///    at `Task.priority = .background`, yielding cooperatively every 100 dirs
///    to avoid blocking higher-priority work.
///
/// ## Performance
/// Each `lstat()` call costs approximately 1us. A volume with 300k directories
/// completes full validation in ~0.3s, well within acceptable background work.
///
/// ## Thread Safety
/// `CacheValidator` is `Sendable` and stateless — all state is local to the
/// ``validate(tree:rootPath:onPriorityPassComplete:onProgress:)`` call.
/// It only reads from the ``FileTree`` (no mutations).
final class CacheValidator: Sendable {

    // MARK: - Types

    /// The result of a full cache validation pass.
    struct ValidationResult: Sendable {
        /// Full paths of directories whose `dirMtime` differs from the filesystem.
        let dirtyDirectories: [String]

        /// Total number of directories checked across both passes.
        let totalChecked: Int

        /// Wall-clock duration of the entire validation (both passes).
        let validationDuration: TimeInterval
    }

    // MARK: - Constants

    /// Maximum depth (inclusive) for the priority pass.
    /// Depth 0 = root, depth 1 = root's children, depth 2 = grandchildren.
    private static let priorityPassMaxDepth = 2

    /// Number of directories between cooperative cancellation checks
    /// during the background pass.
    private static let cancellationCheckInterval = 100

    /// Number of directories between progress callback invocations
    /// during the background pass.
    private static let progressReportInterval = 500

    // MARK: - Initialization

    /// Creates a new cache validator.
    init() {}

    // MARK: - Validation

    /// Validates cached directory metadata against the filesystem.
    ///
    /// Performs a two-pass validation: a fast priority pass for shallow directories
    /// (depth 0-2) followed by a background pass for deeper directories.
    ///
    /// - Parameters:
    ///   - tree: The cached ``FileTree`` to validate.
    ///   - rootPath: The root scan path (e.g., `"/"`).
    ///   - onPriorityPassComplete: Called after top-level dirs are checked (<0.1s).
    ///     Receives the list of dirty directory paths found so far.
    ///   - onProgress: Called periodically during the background pass with
    ///     `(checkedSoFar, totalDirectories)` counts.
    /// - Returns: A ``ValidationResult`` with the complete list of dirty directories.
    func validate(
        tree: FileTree,
        rootPath: String,
        onPriorityPassComplete: @escaping @Sendable ([String]) -> Void = { _ in },
        onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> ValidationResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        // Collect all directory nodes with their full paths and depths
        // using a BFS traversal that builds paths incrementally.
        let directories = collectDirectories(from: tree)

        // Partition into priority (depth <= 2) and background (depth > 2)
        var priorityDirs = [(path: String, dirMtime: UInt64)]()
        var backgroundDirs = [(path: String, dirMtime: UInt64)]()

        for dir in directories {
            if dir.depth <= Self.priorityPassMaxDepth {
                priorityDirs.append((dir.path, dir.dirMtime))
            } else {
                backgroundDirs.append((dir.path, dir.dirMtime))
            }
        }

        let totalDirectories = directories.count
        var allDirtyPaths = [String]()

        // --- Priority Pass ---
        let priorityDirty = validateDirectories(priorityDirs)
        allDirtyPaths.append(contentsOf: priorityDirty)

        onPriorityPassComplete(priorityDirty)

        // --- Background Pass ---
        let checkedAfterPriority = priorityDirs.count

        if !backgroundDirs.isEmpty && !Task.isCancelled {
            let backgroundResult = await Task.detached(priority: .background) {
                [backgroundDirs, checkedAfterPriority, totalDirectories, onProgress] () -> [String] in

                var dirty = [String]()
                var checked = 0

                for dir in backgroundDirs {
                    // Cooperative cancellation
                    if checked % Self.cancellationCheckInterval == 0 && Task.isCancelled {
                        break
                    }

                    if Self.isDirectoryDirty(path: dir.path, cachedMtime: dir.dirMtime) {
                        dirty.append(dir.path)
                    }
                    checked += 1

                    // Progress reporting
                    if checked % Self.progressReportInterval == 0 {
                        onProgress(checkedAfterPriority + checked, totalDirectories)
                    }
                }

                // Final progress report
                if checked % Self.progressReportInterval != 0 {
                    onProgress(checkedAfterPriority + checked, totalDirectories)
                }

                return dirty
            }.value

            allDirtyPaths.append(contentsOf: backgroundResult)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        return ValidationResult(
            dirtyDirectories: allDirtyPaths,
            totalChecked: totalDirectories,
            validationDuration: elapsed
        )
    }

    // MARK: - Directory Collection

    /// A directory entry collected during BFS traversal.
    private struct DirectoryEntry {
        let path: String
        let dirMtime: UInt64
        let depth: Int
    }

    /// Collects all directory nodes from the tree via BFS, building full paths incrementally.
    ///
    /// Instead of calling `FileTree.fullPath(of:)` for each directory (O(depth) per node),
    /// this method traverses the tree top-down, appending each child's name to its parent's
    /// known path. This gives O(1) amortized path construction per node.
    ///
    /// - Parameter tree: The file tree to traverse.
    /// - Returns: An array of directory entries with their full paths and depths.
    private func collectDirectories(from tree: FileTree) -> [DirectoryEntry] {
        let rootIndex = tree.rootIndex
        guard rootIndex > 0, let rootNode = tree.node(at: rootIndex) else {
            return []
        }

        // The root node's name is the root path itself (e.g., "/" or "/Volumes/Data").
        let rootPath = tree.fullPath(of: rootIndex)

        // Pre-allocate conservatively; most volumes have 5-20% directories.
        var result = [DirectoryEntry]()
        result.reserveCapacity(tree.nodeCount / 5)

        // BFS queue: (nodeIndex, fullPath, depth)
        var queue = [(index: UInt32, path: String, depth: Int)]()
        queue.reserveCapacity(1024)

        // Enqueue root if it's a directory
        if rootNode.isDirectory {
            result.append(DirectoryEntry(path: rootPath, dirMtime: rootNode.dirMtime, depth: 0))
        }

        // Seed BFS with root's children
        enqueueChildren(of: rootIndex, parentPath: rootPath, depth: 1, tree: tree, into: &queue)

        var queueHead = 0

        while queueHead < queue.count {
            let (nodeIndex, nodePath, depth) = queue[queueHead]
            queueHead += 1

            guard let node = tree.node(at: nodeIndex) else { continue }

            if node.isDirectory {
                result.append(DirectoryEntry(path: nodePath, dirMtime: node.dirMtime, depth: depth))

                // Enqueue this directory's children for further traversal
                enqueueChildren(of: nodeIndex, parentPath: nodePath, depth: depth + 1, tree: tree, into: &queue)
            }
        }

        return result
    }

    /// Enqueues all children of a node for BFS traversal, building their full paths.
    ///
    /// - Parameters:
    ///   - parentIndex: The index of the parent node.
    ///   - parentPath: The full filesystem path of the parent.
    ///   - depth: The depth of the children being enqueued.
    ///   - tree: The file tree.
    ///   - queue: The BFS queue to append to.
    private func enqueueChildren(
        of parentIndex: UInt32,
        parentPath: String,
        depth: Int,
        tree: FileTree,
        into queue: inout [(index: UInt32, path: String, depth: Int)]
    ) {
        let childIndices = tree.children(of: parentIndex)
        for childIndex in childIndices {
            guard let childNode = tree.node(at: childIndex) else { continue }

            // Only traverse into directories for the BFS; files are skipped
            // since we only validate directory mtimes.
            guard childNode.isDirectory else { continue }

            let childName = tree.name(of: childIndex)
            let childPath: String
            if parentPath == "/" {
                childPath = "/" + childName
            } else if parentPath.hasSuffix("/") {
                childPath = parentPath + childName
            } else {
                childPath = parentPath + "/" + childName
            }

            queue.append((childIndex, childPath, depth))
        }
    }

    // MARK: - Validation Logic

    /// Validates a batch of directories synchronously (used for the priority pass).
    ///
    /// - Parameter directories: Array of `(path, cachedMtime)` tuples.
    /// - Returns: Paths of directories that are dirty (mtime mismatch or deleted).
    private func validateDirectories(_ directories: [(path: String, dirMtime: UInt64)]) -> [String] {
        var dirty = [String]()

        for dir in directories {
            if Self.isDirectoryDirty(path: dir.path, cachedMtime: dir.dirMtime) {
                dirty.append(dir.path)
            }
        }

        return dirty
    }

    /// Checks whether a single directory's cached mtime matches the live filesystem.
    ///
    /// Calls `lstat()` on the path and compares `st_mtimespec.tv_sec` (as `UInt64`)
    /// with the cached `dirMtime`. A mismatch means the directory's contents have
    /// changed (files added, removed, or renamed). If `lstat()` fails (e.g., `ENOENT`),
    /// the directory is considered deleted and therefore dirty.
    ///
    /// - Parameters:
    ///   - path: The full filesystem path to check.
    ///   - cachedMtime: The `dirMtime` stored in the cached ``FileNode``.
    /// - Returns: `true` if the directory is dirty (needs rescan), `false` if unchanged.
    private static func isDirectoryDirty(path: String, cachedMtime: UInt64) -> Bool {
        var st = stat()
        let result = lstat(path, &st)

        if result == 0 {
            let liveMtime = UInt64(st.st_mtimespec.tv_sec)
            return liveMtime != cachedMtime
        } else {
            // lstat() failed — directory was deleted or is inaccessible.
            // Either way, the cache is stale for this path.
            return true
        }
    }
}
