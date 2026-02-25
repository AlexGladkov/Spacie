import Foundation

// MARK: - FileTree

/// Arena-based, memory-efficient file tree using flat arrays and a string pool.
///
/// All ``FileNode`` instances are stored in a single contiguous array, and all
/// file names live in a shared ``StringPool``. Parent-child relationships are
/// encoded via indices (`parentIndex`, `firstChildIndex`, `nextSiblingIndex`),
/// eliminating pointer overhead.
///
/// ## Memory Budget
/// - Each `FileNode` is approximately 64 bytes.
/// - 5M nodes at 64 bytes = ~320 MB (within the 500 MB target with string pool).
///
/// ## Thread Safety
/// The tree is built incrementally during scanning (single writer), then
/// read concurrently by the UI layer. The ``FileTree`` class uses internal
/// locking to ensure safe transitions between build and read phases.
///
/// ## Usage
/// ```swift
/// let tree = FileTree()
/// // Build phase (single writer)
/// for await event in scanStream {
///     if case .fileFound(let raw) = event {
///         tree.insert(raw)
///     }
/// }
/// tree.aggregateSizes()
/// tree.finalizeBuild()
///
/// // Read phase (concurrent readers)
/// let info = tree.nodeInfo(at: 0)
/// let kids = tree.children(of: 0)
/// ```
final class FileTree: @unchecked Sendable {

    // MARK: - Storage

    /// Flat array of all file nodes. Index 0 is reserved as the sentinel "no node" value.
    /// The root of the scanned tree is at index 1.
    private var nodes: [FileNode]

    /// Shared string pool for all file names.
    private(set) var stringPool: StringPool

    /// Path-to-index lookup used during the build phase for fast parent resolution.
    /// Cleared after ``finalizeBuild()`` to reclaim memory.
    private var pathIndex: [String: UInt32]

    /// Lock for thread-safe access transitions between build and read phases.
    private var _lock = os_unfair_lock()

    /// Whether the tree has been finalized (build complete, ready for concurrent reads).
    private(set) var isFinalized: Bool = false

    /// The root path that was scanned.
    private(set) var rootPath: String = ""

    // MARK: - Initialization

    /// Creates an empty file tree with pre-allocated capacity.
    ///
    /// - Parameter estimatedNodeCount: Expected number of nodes for capacity pre-allocation.
    ///   Defaults to 500,000 which covers most user volumes without excessive reallocation.
    init(estimatedNodeCount: Int = 500_000) {
        // Reserve index 0 as the sentinel (null node).
        // The sentinel has all zeroes and is never returned to callers.
        var initialNodes = [FileNode]()
        initialNodes.reserveCapacity(estimatedNodeCount + 1)

        let sentinel = FileNode(
            nameOffset: 0,
            nameLength: 0,
            parentIndex: UInt32.max,
            firstChildIndex: 0,
            nextSiblingIndex: 0,
            logicalSize: 0,
            physicalSize: 0,
            flags: [],
            fileType: .other,
            modTime: 0,
            childCount: 0,
            inode: 0,
            dirMtime: 0
        )
        initialNodes.append(sentinel)

        self.nodes = initialNodes
        self.stringPool = StringPool(initialCapacity: estimatedNodeCount * 20) // ~20 bytes avg name
        self.pathIndex = Dictionary(minimumCapacity: estimatedNodeCount)
    }

    // MARK: - Build Phase

    /// The total number of nodes in the tree (excluding the sentinel at index 0).
    var nodeCount: Int {
        nodes.count - 1
    }

    /// Inserts a ``RawFileNode`` (produced by ``DiskScanner``) into the tree.
    ///
    /// During the build phase, nodes are added one at a time. Parent resolution
    /// uses the internal `pathIndex` dictionary for O(1) lookup.
    ///
    /// - Parameter raw: The raw file node from the scanner.
    /// - Returns: The index of the newly inserted node, or `nil` if insertion failed.
    @discardableResult
    func insert(_ raw: RawFileNode) -> UInt32? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return insertUnlocked(raw)
    }

    /// Inserts a batch of raw file nodes in a single lock acquisition.
    ///
    /// Reduces lock contention from once-per-file to once-per-batch.
    /// Callers should accumulate nodes (e.g., 4096 at a time) before calling.
    ///
    /// - Parameter batch: Array of raw file nodes to insert.
    func insertBatch(_ batch: [RawFileNode]) {
        guard !batch.isEmpty else { return }
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        nodes.reserveCapacity(nodes.count + batch.count)
        for raw in batch {
            insertUnlocked(raw)
        }
    }

    /// Internal insertion logic without lock acquisition.
    ///
    /// Called by ``insert(_:)`` (single node) and ``insertBatch(_:)`` (batched).
    /// The caller **must** hold `_lock` before invoking this method.
    ///
    /// - Parameter raw: The raw file node from the scanner.
    /// - Returns: The index of the newly inserted node, or `nil` if insertion failed.
    @discardableResult
    private func insertUnlocked(_ raw: RawFileNode) -> UInt32? {
        // Deduplication: if a directory node already exists at this path,
        // update its metadata instead of creating a duplicate.
        // BulkDiskScanner emits each directory twice (once as a child of its
        // parent, once as the root when the directory itself is scanned),
        // so without this check the tree would contain duplicate nodes.
        if let existingIdx = pathIndex[raw.path] {
            let i = Int(existingIdx)
            if i > 0 && i < nodes.count
                && nodes[i].isDirectory && raw.flags.contains(.isDirectory)
            {
                // Update metadata on the existing directory node
                if raw.dirMtime != 0 { nodes[i].dirMtime = raw.dirMtime }
                if raw.inode != 0 { nodes[i].inode = raw.inode }
                if raw.modTime != 0 { nodes[i].modTime = raw.modTime }
                if raw.flags.contains(.isDeepScanned) {
                    nodes[i].flags.insert(.isDeepScanned)
                }
                return existingIdx
            }
        }

        // Intern the name
        let (nameOffset, nameLength) = stringPool.append(raw.name)

        // Resolve parent index
        let parentIdx: UInt32
        if raw.parentPath.isEmpty {
            // This is the root node
            parentIdx = 0
            rootPath = raw.path
        } else if let idx = pathIndex[raw.parentPath] {
            parentIdx = idx
        } else {
            // Parent not yet inserted; this can happen if scanner emits
            // children before parents. We'll insert a placeholder parent chain.
            parentIdx = ensureParentChain(for: raw.parentPath)
        }

        let newIndex = UInt32(nodes.count)

        var node = FileNode(
            nameOffset: nameOffset,
            nameLength: nameLength,
            parentIndex: parentIdx,
            firstChildIndex: 0,
            nextSiblingIndex: 0,
            logicalSize: raw.logicalSize,
            physicalSize: raw.physicalSize,
            flags: raw.flags,
            fileType: raw.fileType,
            modTime: raw.modTime,
            childCount: 0,
            entryCount: raw.entryCount,
            inode: raw.inode,
            dirMtime: raw.dirMtime
        )

        // Link as child of parent using the sibling-list pattern:
        // New child becomes the first child, and the previous first child
        // becomes the new child's next sibling.
        if parentIdx < nodes.count && parentIdx > 0 {
            node.nextSiblingIndex = nodes[Int(parentIdx)].firstChildIndex
            nodes[Int(parentIdx)].firstChildIndex = newIndex
            nodes[Int(parentIdx)].childCount &+= 1
        } else if parentIdx == 0 && !raw.parentPath.isEmpty {
            // Sentinel parent; root nodes get linked later
        }

        nodes.append(node)
        pathIndex[raw.path] = newIndex

        return newIndex
    }

    /// Ensures all ancestor directories exist in the tree for the given path.
    ///
    /// If a parent directory hasn't been inserted yet (e.g., the scanner emits
    /// files before their parent directory's post-order event), this method
    /// creates placeholder directory nodes up the chain.
    ///
    /// - Parameter path: The full path whose ancestors must exist.
    /// - Returns: The index of the immediate parent.
    private func ensureParentChain(for path: String) -> UInt32 {
        // Check if already known
        if let idx = pathIndex[path] {
            return idx
        }

        // Compute parent of this path
        let parentOfParent: String
        if let lastSlash = path.lastIndex(of: "/") {
            if lastSlash == path.startIndex {
                if path.count > 1 {
                    // Path is like "/Users" — parent is root "/"
                    parentOfParent = "/"
                } else {
                    // Path is exactly "/" — root has no parent
                    parentOfParent = ""
                }
            } else {
                parentOfParent = String(path[path.startIndex..<lastSlash])
            }
        } else {
            parentOfParent = ""
        }

        // Recurse to ensure the grandparent exists
        let grandparentIdx: UInt32
        if parentOfParent.isEmpty {
            grandparentIdx = 0
        } else {
            grandparentIdx = ensureParentChain(for: parentOfParent)
        }

        // Extract the directory name from the path
        let dirName: String
        if path == "/" {
            dirName = "/"
        } else if let lastSlash = path.lastIndex(of: "/") {
            dirName = String(path[path.index(after: lastSlash)...])
        } else {
            dirName = path
        }

        // Create a placeholder directory node
        let (nameOffset, nameLength) = stringPool.append(dirName)
        let newIndex = UInt32(nodes.count)

        var placeholder = FileNode(
            nameOffset: nameOffset,
            nameLength: nameLength,
            parentIndex: grandparentIdx,
            firstChildIndex: 0,
            nextSiblingIndex: 0,
            logicalSize: 0,
            physicalSize: 0,
            flags: [.isDirectory],
            fileType: .other,
            modTime: 0,
            childCount: 0,
            inode: 0,
            dirMtime: 0
        )

        // Link to grandparent
        if grandparentIdx > 0 && Int(grandparentIdx) < nodes.count {
            placeholder.nextSiblingIndex = nodes[Int(grandparentIdx)].firstChildIndex
            nodes[Int(grandparentIdx)].firstChildIndex = newIndex
            nodes[Int(grandparentIdx)].childCount &+= 1
        }

        nodes.append(placeholder)
        pathIndex[path] = newIndex

        // If we just created the root placeholder, set rootPath
        if grandparentIdx == 0 && path == "/" {
            rootPath = "/"
        }

        return newIndex
    }

    /// Aggregates sizes from leaf nodes up to the root.
    ///
    /// Must be called after all nodes have been inserted and before
    /// ``finalizeBuild()``. Walks the tree bottom-up, summing child sizes
    /// into their parent directories.
    func aggregateSizes() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let count = nodes.count

        // Reset directory sizes to zero before re-aggregating.
        // This makes the method idempotent — safe to call multiple times
        // (e.g., during incremental Phase 2 updates).
        for i in 1..<count where nodes[i].isDirectory {
            nodes[i].logicalSize = 0
            nodes[i].physicalSize = 0
        }

        // Process nodes in reverse order. Since children are always inserted
        // after their parents (or at higher indices due to post-order), iterating
        // backwards naturally processes children before parents.
        for i in stride(from: count - 1, through: 1, by: -1) {
            let parentIdx = Int(nodes[i].parentIndex)
            guard parentIdx > 0, parentIdx < count else { continue }

            nodes[parentIdx].logicalSize &+= nodes[i].logicalSize
            nodes[parentIdx].physicalSize &+= nodes[i].physicalSize
        }
    }

    /// Aggregates entry counts from leaf directories up to the root.
    ///
    /// Similar to ``aggregateSizes()``, walks the tree bottom-up summing
    /// child entry counts into their parents. After aggregation, each
    /// directory's `entryCount` represents the total number of entries
    /// in its entire subtree (including its own direct entries).
    ///
    /// Used after Phase 1 (shallow scan) to make entry-count-based
    /// visualization proportions meaningful.
    func aggregateEntryCounts() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        // NOTE: NOT idempotent. Must be called exactly once.
        // Unlike sizes (where ground truth is on leaf files and dirs start at 0),
        // entryCount ground truth is on directory nodes themselves (direct count
        // from readdir). Zeroing would destroy it.
        let count = nodes.count
        for i in stride(from: count - 1, through: 1, by: -1) {
            let parentIdx = Int(nodes[i].parentIndex)
            guard parentIdx > 0, parentIdx < count else { continue }
            nodes[parentIdx].entryCount &+= nodes[i].entryCount
        }
    }

    /// Diagnostic dump for debugging tree integrity issues.
    /// Writes analysis to /tmp/spacie_tree_diagnostic.txt
    func diagnosticDump() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        var lines: [String] = []
        func log(_ s: String) { lines.append(s) }

        let count = nodes.count
        var fileCount = 0
        var dirCount = 0
        var rawFileSizeSum: UInt64 = 0
        var orphanCount = 0
        var orphanSizeSum: UInt64 = 0
        var rootChildrenSizeSum: UInt64 = 0

        let rootIdx = rootIndex
        let rootNode = rootIdx > 0 && Int(rootIdx) < count ? nodes[Int(rootIdx)] : nil
        log("=== DIAGNOSTIC DUMP ===")
        log("Total nodes (incl sentinel): \(count)")
        log("Root index: \(rootIdx), rootPath: \(rootPath)")
        if let r = rootNode {
            log("Root logicalSize: \(r.logicalSize), childCount: \(r.childCount), firstChildIndex: \(r.firstChildIndex)")
        }

        for i in 1..<count {
            let n = nodes[i]
            if n.isDirectory {
                dirCount += 1
            } else {
                fileCount += 1
                rawFileSizeSum += n.logicalSize
            }
            let pi = Int(n.parentIndex)
            if pi == 0 && UInt32(i) != rootIdx {
                orphanCount += 1
                orphanSizeSum += n.logicalSize
            }
        }

        if let r = rootNode {
            var childIdx = r.firstChildIndex
            var childNum = 0
            while childIdx != 0 && Int(childIdx) < count {
                let child = nodes[Int(childIdx)]
                rootChildrenSizeSum += child.logicalSize
                childNum += 1
                if childNum <= 15 {
                    let cname = stringPool.getString(offset: child.nameOffset, length: child.nameLength)
                    log("  Root child #\(childNum): idx=\(childIdx) name=\(cname) size=\(child.logicalSize) isDir=\(child.isDirectory) parentIdx=\(child.parentIndex)")
                }
                childIdx = child.nextSiblingIndex
            }
            log("Root linked children: \(childNum), their aggregated size sum: \(rootChildrenSizeSum)")
        }

        log("Files: \(fileCount), Dirs: \(dirCount)")
        log("Raw file size sum (non-dir logicalSize): \(rawFileSizeSum) (\(rawFileSizeSum / (1024*1024*1024)) GB)")
        log("Orphans (parentIndex==0, not root): \(orphanCount), orphan size sum: \(orphanSizeSum) (\(orphanSizeSum / (1024*1024*1024)) GB)")

        var badParentCount = 0
        for i in 1..<count {
            let pi = Int(nodes[i].parentIndex)
            if pi != 0 && (pi < 0 || pi >= count) {
                badParentCount += 1
            }
        }
        log("Nodes with out-of-bounds parentIndex: \(badParentCount)")

        // Sample nodes with largest sizes that have parentIndex == 0 (orphans)
        var orphanSamples: [(index: Int, size: UInt64, path: String)] = []
        var indexToPath: [UInt32: String] = [:]
        for (path, idx) in pathIndex {
            indexToPath[idx] = path
        }
        for i in 1..<count {
            let pi = Int(nodes[i].parentIndex)
            if pi == 0 && UInt32(i) != rootIdx {
                orphanSamples.append((i, nodes[i].logicalSize, indexToPath[UInt32(i)] ?? "<unknown>"))
            }
        }
        orphanSamples.sort { $0.size > $1.size }
        if !orphanSamples.isEmpty {
            log("Top 20 orphans by size:")
            for s in orphanSamples.prefix(20) {
                let n = nodes[s.index]
                log("  node[\(s.index)] path=\(s.path) size=\(s.size) isDir=\(n.isDirectory) flags=\(n.flags)")
            }
        }

        log("=== END DIAGNOSTIC DUMP ===")

        // Write to NSLog AND file
        let output = lines.joined(separator: "\n")
        for line in lines {
            NSLog("[SPACIE_DIAG] %@", line)
        }
        // Also try multiple file locations
        let homeDir = NSHomeDirectory()
        let diagPath = homeDir + "/spacie_diagnostic.txt"
        try? output.write(toFile: diagPath, atomically: true, encoding: .utf8)
        NSLog("[SPACIE_DIAG] Written to %@", diagPath)
    }

    /// Finalizes the build phase, releasing the path index to reclaim memory.
    ///
    /// After this call, no further insertions are allowed and the tree
    /// becomes safe for concurrent reads.
    func finalizeBuild() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        pathIndex.removeAll()
        isFinalized = true
    }

    // MARK: - Node Access

    /// Returns the ``FileNode`` at the given index, or `nil` if the index is invalid.
    ///
    /// - Parameter index: The node index (1-based; 0 is the sentinel).
    /// - Returns: The file node, or `nil` if the index is out of bounds or zero.
    func node(at index: UInt32) -> FileNode? {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return nil }
        return nodes[i]
    }

    // MARK: - Navigation

    /// Returns the indices of all direct children of the node at the given index.
    ///
    /// Traverses the linked sibling list starting from `firstChildIndex`.
    ///
    /// - Parameter index: The parent node index.
    /// - Returns: An array of child node indices.
    func children(of index: UInt32) -> [UInt32] {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return [] }

        var result = [UInt32]()
        let expectedCount = nodes[i].childCount
        result.reserveCapacity(Int(expectedCount))

        var childIdx = nodes[i].firstChildIndex
        while childIdx != 0 && Int(childIdx) < nodes.count {
            result.append(childIdx)
            childIdx = nodes[Int(childIdx)].nextSiblingIndex
        }

        return result
    }

    /// Returns the parent index of the node, or `nil` if it's the root.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The parent's index, or `nil` if the node is the root or invalid.
    func parent(of index: UInt32) -> UInt32? {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return nil }
        let parentIdx = nodes[i].parentIndex
        guard parentIdx > 0, Int(parentIdx) < nodes.count else { return nil }
        return parentIdx
    }

    // MARK: - Node Info

    /// Returns rich display information for the node at the given index.
    ///
    /// Resolves the name from the string pool and computes the depth by
    /// walking up to the root.
    ///
    /// - Parameter index: The node index.
    /// - Returns: A ``FileNodeInfo`` with resolved name and path. Returns a
    ///   placeholder info for invalid indices rather than nil, since most call
    ///   sites operate on known-valid indices.
    func nodeInfo(at index: UInt32) -> FileNodeInfo {
        let i = Int(index)
        guard i > 0, i < nodes.count else {
            return FileNodeInfo(
                id: index,
                name: "",
                fullPath: "",
                logicalSize: 0,
                physicalSize: 0,
                isDirectory: false,
                fileType: .other,
                modificationDate: .distantPast,
                childCount: 0,
                depth: 0,
                flags: [],
                dirMtime: 0
            )
        }

        let node = nodes[i]
        let name = stringPool.getString(offset: node.nameOffset, length: node.nameLength)
        let path = fullPath(of: index)
        let depth = computeDepth(of: index)

        return FileNodeInfo(
            id: index,
            name: name,
            fullPath: path,
            logicalSize: node.logicalSize,
            physicalSize: node.physicalSize,
            isDirectory: node.isDirectory,
            fileType: node.fileType,
            modificationDate: node.modificationDate,
            childCount: node.childCount,
            entryCount: node.entryCount,
            depth: depth,
            flags: node.flags,
            dirMtime: node.dirMtime
        )
    }

    /// Builds the full file system path for a node by walking up the parent chain.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The full path from root to this node, separated by `/`.
    func fullPath(of index: UInt32) -> String {
        var components = [String]()
        var current = index

        while current > 0 && Int(current) < nodes.count {
            let node = nodes[Int(current)]
            let name = stringPool.getString(offset: node.nameOffset, length: node.nameLength)
            components.append(name)
            current = node.parentIndex
        }

        components.reverse()

        if components.isEmpty { return "/" }

        // If the root component starts with "/", don't prepend another slash
        let first = components[0]
        if first.hasPrefix("/") {
            if components.count == 1 { return first }
            // When root is exactly "/", avoid producing "//child"
            if first == "/" {
                return "/" + components.dropFirst().joined(separator: "/")
            }
            return first + "/" + components.dropFirst().joined(separator: "/")
        }

        return "/" + components.joined(separator: "/")
    }

    /// Computes the depth of a node by counting parent hops to the root.
    private func computeDepth(of index: UInt32) -> Int {
        var depth = 0
        var current = nodes[Int(index)].parentIndex
        while current > 0 && Int(current) < nodes.count {
            depth += 1
            current = nodes[Int(current)].parentIndex
        }
        return depth
    }

    // MARK: - Sorted Access

    /// Returns the children of a node sorted by the specified order.
    ///
    /// Uses the shared ``TreeSortOrder`` type which combines ``SortCriteria``
    /// with an ascending/descending flag.
    ///
    /// - Parameters:
    ///   - index: The parent node index.
    ///   - order: The sort order (criteria + direction).
    /// - Returns: An array of sorted child indices.
    func sortedChildren(of index: UInt32, by order: TreeSortOrder) -> [UInt32] {
        let childIndices = children(of: index)
        guard childIndices.count > 1 else { return childIndices }

        return childIndices.sorted(by: { (a: UInt32, b: UInt32) -> Bool in
            let nodeA = nodes[Int(a)]
            let nodeB = nodes[Int(b)]

            let result: Bool
            switch order.criteria {
            case .size:
                result = nodeA.logicalSize < nodeB.logicalSize
            case .name:
                let nameA = stringPool.getString(offset: nodeA.nameOffset, length: nodeA.nameLength)
                let nameB = stringPool.getString(offset: nodeB.nameOffset, length: nodeB.nameLength)
                result = nameA.localizedStandardCompare(nameB) == .orderedAscending
            case .date:
                result = nodeA.modTime < nodeB.modTime
            case .type:
                result = nodeA.fileType.rawValue < nodeB.fileType.rawValue
            }

            return order.ascending ? result : !result
        })
    }

    // MARK: - Queries

    /// Returns the indices of the largest files in the tree.
    ///
    /// Scans all nodes to find the top N files (non-directories) by logical size.
    /// Optionally filters by a minimum size threshold.
    ///
    /// - Parameters:
    ///   - count: Maximum number of results to return.
    ///   - minSize: Optional minimum file size in bytes. Files smaller are excluded.
    /// - Returns: An array of node indices sorted by size descending.
    func topFiles(count: Int, minSize: UInt64? = nil) -> [UInt32] {
        // Use a simple sorted insertion approach:
        // For large trees, a min-heap of size `count` would be optimal,
        // but the constant factor of Array.sort on ~1M elements is acceptable.
        var candidates = [(index: UInt32, size: UInt64)]()
        candidates.reserveCapacity(min(count, nodes.count / 2, 1_000_000))

        let threshold = minSize ?? 0

        for i in 1..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory, node.logicalSize >= threshold else { continue }
            candidates.append((UInt32(i), node.logicalSize))
        }

        // Sort descending and take the top N
        candidates.sort { $0.size > $1.size }
        let resultCount = min(count, candidates.count)
        return candidates.prefix(resultCount).map(\.index)
    }

    /// Returns the indices of all files matching a specific ``FileType``.
    ///
    /// - Parameter type: The file type to filter by.
    /// - Returns: An array of matching node indices.
    func filesByType(_ type: FileType) -> [UInt32] {
        var result = [UInt32]()

        for i in 1..<nodes.count {
            if nodes[i].fileType == type && !nodes[i].isDirectory {
                result.append(UInt32(i))
            }
        }

        return result
    }

    /// Returns the name of the node at the given index from the string pool.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The file/directory name, or an empty string if the index is invalid.
    func name(of index: UInt32) -> String {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return "" }
        let node = nodes[i]
        return stringPool.getString(offset: node.nameOffset, length: node.nameLength)
    }

    /// Returns the logical size of the node at the given index.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The logical size in bytes, or 0 if the index is invalid.
    func logicalSize(of index: UInt32) -> UInt64 {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].logicalSize
    }

    /// Returns the physical size of the node at the given index.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The physical size in bytes, or 0 if the index is invalid.
    func physicalSize(of index: UInt32) -> UInt64 {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].physicalSize
    }

    // MARK: - Root Access

    /// The index of the root node (always 1 if the tree has been populated).
    var rootIndex: UInt32 {
        nodes.count > 1 ? 1 : 0
    }

    // MARK: - Entry Count Access

    /// Returns the `readdir()` entry count for the directory at the given index.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The entry count, or 0 if the index is invalid.
    func entryCount(of index: UInt32) -> UInt32 {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].entryCount
    }

    /// Returns all directory node indices with their entry counts,
    /// sorted by entry count descending (heaviest directories first).
    ///
    /// Used by ``DeepScanner`` to prioritize scanning of the largest directories.
    ///
    /// - Returns: Array of `(index, entryCount)` tuples for all directory nodes.
    func allDirectoriesByEntryCount() -> [(index: UInt32, entryCount: UInt32)] {
        var dirs: [(index: UInt32, entryCount: UInt32)] = []
        dirs.reserveCapacity(nodes.count / 4) // rough estimate

        for i in 1..<nodes.count {
            if nodes[i].isDirectory && !nodes[i].isExcluded && !nodes[i].isRestricted {
                dirs.append((UInt32(i), nodes[i].entryCount))
            }
        }

        dirs.sort { $0.entryCount > $1.entryCount }
        return dirs
    }

    // MARK: - Virtual Node Support

    /// Inserts a virtual "Other" node as a child of the root for Smart Scan.
    ///
    /// The virtual node represents the aggregate size of unscanned directories
    /// plus APFS overhead. It is displayed with special styling (hatched/muted)
    /// and does not support drill-down or deletion.
    ///
    /// Must be called **after** ``aggregateSizes()`` and **before** ``finalizeBuild()``.
    ///
    /// - Parameter otherSize: The byte size attributed to unscanned directories and overhead.
    /// - Returns: The index of the inserted virtual node, or `nil` if the tree has no root.
    @discardableResult
    func insertVirtualOtherNode(otherSize: UInt64) -> UInt32? {
        let virtualPath = rootPath == "/" ? "/[Other]" : rootPath + "/[Other]"
        let raw = RawFileNode(
            name: "Other",
            path: virtualPath,
            logicalSize: otherSize,
            physicalSize: otherSize,
            flags: [.isDirectory, .isVirtual],
            fileType: .other,
            modTime: 0,
            inode: 0,
            depth: 1,
            parentPath: rootPath
        )
        return insert(raw)
    }

    /// Updates the size of the virtual "Other" node.
    ///
    /// Used during auto-rescan to shrink the "Other" segment as more directories
    /// are scanned incrementally. Finds the virtual node by scanning for the
    /// ``FileNodeFlags/isVirtual`` flag and updates both logical and physical sizes.
    ///
    /// - Parameter newSize: The updated byte size for the virtual node.
    func updateVirtualOtherSize(_ newSize: UInt64) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        for i in 1..<nodes.count {
            if nodes[i].flags.contains(.isVirtual) {
                nodes[i].logicalSize = newSize
                nodes[i].physicalSize = newSize
                return
            }
        }
    }

    // MARK: - Serialization Support

    /// Provides read-only access to the raw node array for binary serialization.
    var serializedNodes: [FileNode] {
        nodes
    }

    /// Reconstructs a FileTree from previously serialized data.
    ///
    /// - Parameters:
    ///   - nodes: The flat array of ``FileNode`` values.
    ///   - stringPool: The reconstructed ``StringPool``.
    ///   - rootPath: The root path of the original scan.
    init(deserializedNodes: [FileNode], stringPool: StringPool, rootPath: String) {
        self.nodes = deserializedNodes
        self.stringPool = stringPool
        self.pathIndex = [:]
        self.rootPath = rootPath
        self.isFinalized = true
    }

    // MARK: - WAL Patching

    /// Rebuilds the ``pathIndex`` from existing nodes, enabling WAL patch operations.
    ///
    /// When a `FileTree` is deserialized from cache (via ``init(deserializedNodes:stringPool:rootPath:)``),
    /// it is marked as `isFinalized = true` and `pathIndex` is empty. This method reconstructs the
    /// path-to-index mapping by performing a BFS traversal from the root node, which is required
    /// before calling ``applyWALPatch(dirPath:walNodes:walStringPoolData:)``.
    ///
    /// The traversal is O(n) — each node is visited exactly once.
    ///
    /// Must be called on a deserialized tree before applying WAL patches.
    func prepareForPatching() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        isFinalized = false
        pathIndex = Dictionary(minimumCapacity: nodes.count)

        guard nodes.count > 1 else { return }

        // The root is at index 1. Its full path is rootPath.
        pathIndex[rootPath] = 1

        // BFS queue: (nodeIndex, fullPath)
        var queue = [(index: UInt32, path: String)]()
        queue.reserveCapacity(nodes.count)
        queue.append((1, rootPath))

        var head = 0
        while head < queue.count {
            let (parentIndex, parentPath) = queue[head]
            head += 1

            var childIdx = nodes[Int(parentIndex)].firstChildIndex
            while childIdx != 0 && Int(childIdx) < nodes.count {
                let childNode = nodes[Int(childIdx)]
                let childName = stringPool.getString(
                    offset: childNode.nameOffset,
                    length: childNode.nameLength
                )

                let childPath = parentPath == "/" ? "/" + childName : parentPath + "/" + childName
                pathIndex[childPath] = childIdx
                queue.append((childIdx, childPath))

                childIdx = childNode.nextSiblingIndex
            }
        }
    }

    /// Applies a WAL patch: replaces the subtree of `dirPath` with nodes from the WAL entry.
    ///
    /// The WAL nodes reference names in their own string pool (provided as raw `Data`).
    /// Each WAL node is converted to a ``RawFileNode`` and inserted via the standard
    /// ``insertUnlocked(_:)`` path, which re-interns names into the tree's main ``StringPool``.
    ///
    /// Old children of the patched directory are unlinked (their `firstChildIndex` is zeroed).
    /// The orphaned nodes remain in the arena and are cleaned up on the next blob compaction.
    ///
    /// - Parameters:
    ///   - dirPath: The full path of the directory whose children should be replaced.
    ///   - walNodes: The ``FileNode`` structs from the WAL entry.
    ///   - walStringPoolData: Raw bytes of the ``StringPool`` for the WAL nodes.
    func applyWALPatch(dirPath: String, walNodes: [FileNode], walStringPoolData: Data) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        // 1. Find the directory in pathIndex
        guard let dirIndex = pathIndex[dirPath] else {
            print("[WALPatch] Directory not found in pathIndex: \(dirPath)")
            return
        }

        let dirIdx = Int(dirIndex)
        guard dirIdx > 0, dirIdx < nodes.count else {
            print("[WALPatch] Invalid directory index \(dirIdx) for path: \(dirPath)")
            return
        }

        // 2. Remove old children from pathIndex (before unlinking)
        removeSubtreeFromPathIndex(at: dirIdx)

        // 3. Unlink old children — orphaned nodes stay in arena
        nodes[dirIdx].firstChildIndex = 0
        nodes[dirIdx].childCount = 0

        // 4. Insert new nodes from the WAL
        let walPool = StringPool(deserializedFrom: walStringPoolData)

        for walNode in walNodes {
            // Resolve the node's name from the WAL StringPool
            let name = walPool.getString(
                offset: walNode.nameOffset,
                length: walNode.nameLength
            )

            let childPath = dirPath == "/" ? "/" + name : dirPath + "/" + name

            // Determine the parent path for this node.
            // WAL nodes are stored flat — all are direct children of the patched directory.
            // Their parentIndex values are meaningless in the main tree context.
            let parentPath = dirPath

            let raw = RawFileNode(
                name: name,
                path: childPath,
                logicalSize: walNode.logicalSize,
                physicalSize: walNode.physicalSize,
                flags: walNode.flags,
                fileType: walNode.fileType,
                modTime: walNode.modTime,
                inode: walNode.inode,
                depth: 0, // depth is not used by insertUnlocked
                parentPath: parentPath,
                entryCount: walNode.entryCount,
                dirMtime: walNode.dirMtime
            )

            insertUnlocked(raw)
        }
    }

    /// Recursively removes all descendants of the node at `index` from ``pathIndex``.
    ///
    /// Walks the child linked list via `firstChildIndex` / `nextSiblingIndex` and
    /// removes each descendant's full path from the path index. The node at `index`
    /// itself is **not** removed — only its children and their subtrees.
    ///
    /// The caller **must** hold `_lock` before invoking this method.
    ///
    /// - Parameter index: The node index whose descendants should be removed from pathIndex.
    private func removeSubtreeFromPathIndex(at index: Int) {
        var childIdx = nodes[index].firstChildIndex
        while childIdx != 0 && Int(childIdx) < nodes.count {
            let childIndex = Int(childIdx)

            // Recursively remove grandchildren first
            removeSubtreeFromPathIndex(at: childIndex)

            // Build the full path for this child and remove it from pathIndex
            let childPath = fullPath(of: childIdx)
            pathIndex.removeValue(forKey: childPath)

            childIdx = nodes[childIndex].nextSiblingIndex
        }
    }

    // MARK: - Subscript Access

    /// Provides direct subscript access to the underlying ``FileNode`` at the given index.
    ///
    /// - Parameter index: The node index (0-based into the flat array).
    /// - Returns: The ``FileNode`` at that index.
    /// - Note: Index 0 is the sentinel. Valid tree nodes start at index 1.
    subscript(_ index: UInt32) -> FileNode {
        let i = Int(index)
        guard i >= 0, i < nodes.count else { return nodes[0] }
        return nodes[i]
    }

    // MARK: - Size by Mode

    /// Returns the size of the node at the given index using the specified size mode.
    ///
    /// - Parameters:
    ///   - index: The node index.
    ///   - mode: Whether to return logical or physical size.
    /// - Returns: The size in bytes, or 0 if the index is invalid.
    func size(of index: UInt32, mode: SizeMode) -> UInt64 {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        switch mode {
        case .logical:
            return nodes[i].logicalSize
        case .physical:
            return nodes[i].physicalSize
        }
    }

    // MARK: - Diagnostics

    /// Returns memory usage statistics for the tree.
    var memoryUsage: (nodesBytes: Int, stringPoolBytes: Int, totalBytes: Int) {
        let nodesBytes = nodes.count * MemoryLayout<FileNode>.stride
        let poolBytes = stringPool.byteCount
        let total = nodesBytes + poolBytes
        return (nodesBytes, poolBytes, total)
    }
}
