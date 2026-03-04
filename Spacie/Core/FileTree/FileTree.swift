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
    private var _entryCountsAggregated: Bool = false

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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return nodes.count - 1
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
        // Only index directories — files are never looked up by path.
        // Indexing all files would grow pathIndex to O(total files), consuming
        // gigabytes of memory on large volumes (e.g. 2 GB for 16M files at 100-char paths).
        // Directories must remain indexed for parent resolution and incremental rescans.
        if raw.flags.contains(.isDirectory) {
            pathIndex[raw.path] = newIndex
        }

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
    ///
    /// Iterative implementation to avoid call-stack overflow on deeply nested paths.
    private func ensureParentChain(for path: String) -> UInt32 {
        if let idx = pathIndex[path] { return idx }

        // Collect all missing path segments walking upward (bottom → top)
        var missing: [String] = []
        var current = path
        while !current.isEmpty && pathIndex[current] == nil {
            missing.append(current)
            current = parentPathComponent(of: current)
        }

        // Insert from top → bottom so each parent exists before its child
        missing.reverse()

        for missingPath in missing {
            let parentStr = parentPathComponent(of: missingPath)
            let parentIdx: UInt32 = parentStr.isEmpty ? 0 : (pathIndex[parentStr] ?? 0)

            let dirName: String
            if missingPath == "/" {
                dirName = "/"
            } else if let lastSlash = missingPath.lastIndex(of: "/") {
                dirName = String(missingPath[missingPath.index(after: lastSlash)...])
            } else {
                dirName = missingPath
            }

            let (nameOffset, nameLength) = stringPool.append(dirName)
            let newIndex = UInt32(nodes.count)

            var placeholder = FileNode(
                nameOffset: nameOffset,
                nameLength: nameLength,
                parentIndex: parentIdx,
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

            if parentIdx > 0 && Int(parentIdx) < nodes.count {
                placeholder.nextSiblingIndex = nodes[Int(parentIdx)].firstChildIndex
                nodes[Int(parentIdx)].firstChildIndex = newIndex
                nodes[Int(parentIdx)].childCount &+= 1
            }

            nodes.append(placeholder)
            pathIndex[missingPath] = newIndex

            if parentIdx == 0 && missingPath == "/" {
                rootPath = "/"
            }
        }

        return pathIndex[path] ?? 0
    }

    /// Returns the parent path string for a given path.
    private func parentPathComponent(of path: String) -> String {
        guard let lastSlash = path.lastIndex(of: "/") else { return "" }
        if lastSlash == path.startIndex {
            return path.count > 1 ? "/" : ""
        }
        return String(path[path.startIndex..<lastSlash])
    }

    /// Aggregates sizes from leaf nodes up to the root.
    ///
    /// Must be called after all nodes have been inserted and before
    /// ``finalizeBuild()``. Traverses the tree via the children linked list
    /// (BFS from root) so that only nodes actually reachable from the root are
    /// counted. This keeps the result consistent with ``buildDistribution()``
    /// and prevents WAL-replaced nodes (which remain in the arena with a valid
    /// `parentIndex` but are unlinked from the children chain) from
    /// double-counting alongside their replacements.
    ///
    /// **Virtual nodes** (``FileNodeFlags/isVirtual``) are excluded from the
    /// directory-size reset so their externally-assigned sizes (e.g. the Smart
    /// Scan "Other" placeholder representing unscanned space) are preserved and
    /// propagated to the root correctly.
    func aggregateSizes() {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let count = nodes.count
        guard count > 1 else { return }

        // Reset real directory sizes to zero before re-aggregating.
        // Virtual directories (Smart Scan "Other" node) keep their externally-set size.
        for i in 1..<count where nodes[i].isDirectory && !nodes[i].isVirtual {
            nodes[i].logicalSize = 0
            nodes[i].physicalSize = 0
        }

        // BFS from root to collect all nodes reachable via the children linked list.
        // Processing them in reverse BFS order (leaves first) ensures each node's
        // accumulated size is complete before it is added to its parent.
        var bfsOrder = [UInt32]()
        bfsOrder.reserveCapacity(count - 1)
        var queue = [UInt32]()
        queue.reserveCapacity(count - 1)
        queue.append(1) // root is always at index 1
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            bfsOrder.append(current)
            let i = Int(current)
            guard i > 0, i < count, nodes[i].isDirectory else { continue }
            var childIdx = nodes[i].firstChildIndex
            while childIdx != 0 && Int(childIdx) < count {
                queue.append(childIdx)
                childIdx = nodes[Int(childIdx)].nextSiblingIndex
            }
        }

        // Process in reverse BFS order: children before parents.
        for j in stride(from: bfsOrder.count - 1, through: 0, by: -1) {
            let current = Int(bfsOrder[j])
            let parentIdx = Int(nodes[current].parentIndex)
            guard parentIdx > 0, parentIdx < count else { continue }
            nodes[parentIdx].logicalSize &+= nodes[current].logicalSize
            nodes[parentIdx].physicalSize &+= nodes[current].physicalSize
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

        // Guard: must be called exactly once. Entry counts accumulate on top of
        // per-directory readdir values, so a second call would double them.
        guard !_entryCountsAggregated else { return }
        _entryCountsAggregated = true

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

        let rootIdx: UInt32 = nodes.count > 1 ? 1 : 0
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _children(of: index)
    }

    private func _children(of index: UInt32) -> [UInt32] {
        let i = Int(index)
        guard i > 0, i < nodes.count else { return [] }

        var result = [UInt32]()
        let expectedCount = nodes[i].childCount
        result.reserveCapacity(Int(expectedCount))

        var childIdx = nodes[i].firstChildIndex
        var safety = 0
        let maxIterations = nodes.count
        while childIdx != 0 && Int(childIdx) < nodes.count && safety < maxIterations {
            result.append(childIdx)
            childIdx = nodes[Int(childIdx)].nextSiblingIndex
            safety += 1
        }

        return result
    }

    /// Returns the parent index of the node, or `nil` if it's the root.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The parent's index, or `nil` if the node is the root or invalid.
    func parent(of index: UInt32) -> UInt32? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        let path = _fullPath(of: index)
        let depth = _computeDepth(of: index)

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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _fullPath(of: index)
    }

    private func _fullPath(of index: UInt32) -> String {
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
    private func _computeDepth(of index: UInt32) -> Int {
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let childIndices = _children(of: index)
        guard childIndices.count > 1 else { return childIndices }

        return childIndices.sorted(by: { (a: UInt32, b: UInt32) -> Bool in
            let nodeA = self.nodes[Int(a)]
            let nodeB = self.nodes[Int(b)]

            let result: Bool
            switch order.criteria {
            case .size:
                result = nodeA.logicalSize < nodeB.logicalSize
            case .name:
                let nameA = self.stringPool.getString(offset: nodeA.nameOffset, length: nodeA.nameLength)
                let nameB = self.stringPool.getString(offset: nodeB.nameOffset, length: nodeB.nameLength)
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].logicalSize
    }

    /// Returns the logical size of the node identified by the given path.
    ///
    /// Only works during the build phase while `pathIndex` is populated.
    /// Returns 0 if the path is not found or the tree is finalized.
    ///
    /// - Parameter path: The full file-system path of the node.
    /// - Returns: The logical size in bytes, or 0 if the path is not found.
    func logicalSize(ofPath path: String) -> UInt64 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard let idx = pathIndex[path] else { return 0 }
        let i = Int(idx)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].logicalSize
    }

    /// Returns the physical size of the node at the given index.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The physical size in bytes, or 0 if the index is invalid.
    func physicalSize(of index: UInt32) -> UInt64 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }
        return nodes[i].physicalSize
    }

    // MARK: - Root Access

    /// The index of the root node (always 1 if the tree has been populated).
    var rootIndex: UInt32 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return nodes.count > 1 ? 1 : 0
    }

    // MARK: - Entry Count Access

    /// Returns the `readdir()` entry count for the directory at the given index.
    ///
    /// - Parameter index: The node index.
    /// - Returns: The entry count, or 0 if the index is invalid.
    func entryCount(of index: UInt32) -> UInt32 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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

    // MARK: - Node Removal

    /// Removes the node at the given index from the tree.
    ///
    /// Unlinks the node from its parent's child list, zeroes its sizes so that
    /// a subsequent ``aggregateSizes()`` reflects the deletion, and removes its
    /// path from the ``pathIndex``. The node slot in the flat array is left in
    /// place (arena approach — no compaction).
    ///
    /// - Parameter index: The node index to remove.
    /// - Returns: The logical size of the removed node (for callers that need to
    ///   report deleted bytes), or 0 if the index was invalid.
    @discardableResult
    func removeNode(at index: UInt32) -> UInt64 {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let i = Int(index)
        guard i > 0, i < nodes.count else { return 0 }

        let deletedSize = nodes[i].logicalSize

        // Unlink from parent's child linked list
        let parentIdx = Int(nodes[i].parentIndex)
        if parentIdx > 0, parentIdx < nodes.count {
            if nodes[parentIdx].firstChildIndex == index {
                // Node is the first child — advance first child pointer
                nodes[parentIdx].firstChildIndex = nodes[i].nextSiblingIndex
            } else {
                // Walk sibling chain to find the predecessor
                var sibIdx = nodes[parentIdx].firstChildIndex
                var safety = 0
                let maxIter = nodes.count
                while sibIdx != 0, Int(sibIdx) < nodes.count, safety < maxIter {
                    if nodes[Int(sibIdx)].nextSiblingIndex == index {
                        nodes[Int(sibIdx)].nextSiblingIndex = nodes[i].nextSiblingIndex
                        break
                    }
                    sibIdx = nodes[Int(sibIdx)].nextSiblingIndex
                    safety += 1
                }
            }
            if nodes[parentIdx].childCount > 0 {
                nodes[parentIdx].childCount -= 1
            }
        }

        // Zero out the node so aggregateSizes() sees no contribution
        nodes[i].logicalSize = 0
        nodes[i].physicalSize = 0
        nodes[i].nextSiblingIndex = 0
        nodes[i].parentIndex = 0

        // Remove from path index
        // Walk pathIndex to find entries pointing to this index
        let toRemove = pathIndex.filter { $0.value == index }.map(\.key)
        for key in toRemove { pathIndex.removeValue(forKey: key) }

        return deletedSize
    }

    // MARK: - Serialization Support

    /// Provides read-only access to the raw node array for binary serialization.
    var serializedNodes: [FileNode] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return nodes
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
                if childNode.isDirectory {
                    pathIndex[childPath] = childIdx
                }
                if childNode.isDirectory {
                    queue.append((childIdx, childPath))
                }

                childIdx = childNode.nextSiblingIndex
            }
        }
    }

    /// Applies a WAL patch: replaces the children of `dirPath` with nodes from the WAL entry,
    /// while **preserving the inner structure** of subdirectories that still exist in the WAL.
    ///
    /// ## Strategy
    /// WAL entries only capture one directory level at a time (flat list of direct children).
    /// A naive bulk-replace would lose the entire subtree of every subdirectory, causing
    /// aggregateSizes() to show those directories as empty.
    ///
    /// Instead, this method performs a *smart* replacement:
    /// 1. Build a name → walNode map for O(1) lookup.
    /// 2. Walk old children:
    ///    - **Old dir still in WAL** → keep (preserve subtree, update metadata only).
    ///    - **Old dir removed from WAL** → remove from pathIndex + orphan.
    ///    - **Old file** → orphan unconditionally (WAL re-inserts files with fresh sizes).
    /// 3. Reset dirIdx's child list and re-link kept directories.
    /// 4. Insert new WAL files and any newly-appearing directories.
    ///
    /// - Parameters:
    ///   - dirPath: The full path of the directory whose children should be replaced.
    ///   - walNodes: The ``FileNode`` structs from the WAL entry (flat, direct children only).
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

        // 2. Build name → walNode map for O(1) lookup during the old-children walk
        let walPool = StringPool(deserializedFrom: walStringPoolData)
        var walByName: [String: FileNode] = [:]
        walByName.reserveCapacity(walNodes.count)
        for walNode in walNodes {
            let name = walPool.getString(offset: walNode.nameOffset, length: walNode.nameLength)
            walByName[name] = walNode
        }

        // 3. Walk old children: keep dirs that still exist in the WAL; orphan everything else
        var keptDirIndices: [Int] = []
        var keptDirNames: Set<String> = []

        var childIdx = nodes[dirIdx].firstChildIndex
        while childIdx != 0 && Int(childIdx) < nodes.count {
            let ci = Int(childIdx)
            let next = nodes[ci].nextSiblingIndex
            let childName = stringPool.getString(
                offset: nodes[ci].nameOffset,
                length: nodes[ci].nameLength
            )

            if nodes[ci].isDirectory {
                if let walNode = walByName[childName] {
                    // Dir still present in WAL — preserve its subtree, refresh metadata only
                    if walNode.dirMtime != 0 { nodes[ci].dirMtime = walNode.dirMtime }
                    if walNode.inode   != 0 { nodes[ci].inode    = walNode.inode   }
                    if walNode.modTime != 0 { nodes[ci].modTime  = walNode.modTime }
                    keptDirIndices.append(ci)
                    keptDirNames.insert(childName)
                } else {
                    // Dir removed from WAL — clean up pathIndex and orphan
                    let childPath = dirPath == "/" ? "/" + childName : dirPath + "/" + childName
                    pathIndex.removeValue(forKey: childPath)
                    removeSubtreeFromPathIndex(at: ci)
                    nodes[ci].parentIndex = 0
                }
            } else {
                // File — orphan unconditionally; WAL re-inserts files with fresh sizes
                nodes[ci].parentIndex = 0
            }

            childIdx = next
        }

        // 4. Detach all old children from dirIdx
        nodes[dirIdx].firstChildIndex = 0
        nodes[dirIdx].childCount = 0

        // 5. Re-link kept directories (their inner subtrees remain intact)
        for idx in keptDirIndices {
            nodes[idx].parentIndex = UInt32(dirIdx)
            nodes[idx].nextSiblingIndex = nodes[dirIdx].firstChildIndex
            nodes[dirIdx].firstChildIndex = UInt32(idx)
            nodes[dirIdx].childCount &+= 1
        }

        // 6. Insert new WAL nodes: files and newly-appearing directories
        //    (skip directories we already kept above — their subtrees are preserved)
        for walNode in walNodes {
            let name = walPool.getString(offset: walNode.nameOffset, length: walNode.nameLength)

            if walNode.isDirectory && keptDirNames.contains(name) {
                continue // Already re-linked in step 5
            }

            let childPath = dirPath == "/" ? "/" + name : dirPath + "/" + name
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
                parentPath: dirPath,
                entryCount: walNode.entryCount,
                dirMtime: walNode.dirMtime
            )
            insertUnlocked(raw)
        }
    }

    /// Iteratively removes all descendants of the node at `index` from ``pathIndex``.
    ///
    /// Uses an explicit stack to avoid call-stack overflow on deeply nested trees
    /// (e.g., `node_modules` chains that can reach depth 5000+).
    ///
    /// The caller **must** hold `_lock` before invoking this method.
    ///
    /// - Parameter index: The node index whose descendants should be removed from pathIndex.
    private func removeSubtreeFromPathIndex(at index: Int) {
        var stack: [Int] = [index]
        while let current = stack.popLast() {
            var childIdx = nodes[current].firstChildIndex
            while childIdx != 0 && Int(childIdx) < nodes.count {
                let childIndex = Int(childIdx)
                // Only directories are in pathIndex; skip files entirely.
                if nodes[childIndex].isDirectory {
                    stack.append(childIndex)
                    let childPath = _fullPath(of: childIdx)
                    pathIndex.removeValue(forKey: childPath)
                }
                childIdx = nodes[childIndex].nextSiblingIndex
            }
        }
    }

// MARK: - Subscript Access

    /// Provides direct subscript access to the underlying ``FileNode`` at the given index.
    ///
    /// - Parameter index: The node index (0-based into the flat array).
    /// - Returns: The ``FileNode`` at that index.
    /// - Note: Index 0 is the sentinel. Valid tree nodes start at index 1.
    subscript(_ index: UInt32) -> FileNode {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
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
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let nodesBytes = nodes.count * MemoryLayout<FileNode>.stride
        let poolBytes = stringPool.byteCount
        let total = nodesBytes + poolBytes
        return (nodesBytes, poolBytes, total)
    }

    // MARK: - Duplicate Detection

    /// Groups file node indices by logical size for duplicate detection.
    /// Single-pass O(N), one lock acquisition. Deduplicates hardlinks by inode.
    /// - Parameters:
    ///   - minSize: Minimum file size in bytes (default 4096).
    ///   - excludeHardLinks: If true, skips files with the same inode.
    /// - Returns: Dictionary mapping size -> array of (nodeIndex, inode) tuples.
    ///            Only sizes with 2+ distinct entries are included.
    func buildSizeBuckets(
        minSize: UInt64 = 4096,
        excludeHardLinks: Bool = true
    ) -> [UInt64: [(index: UInt32, inode: UInt64)]] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        var sizeMap: [UInt64: [(index: UInt32, inode: UInt64)]] = [:]
        var seenInodes: [UInt64: Set<UInt64>] = [:]

        for i in 1..<nodes.count {
            let node = nodes[i]
            guard !node.isDirectory,
                  !node.isSymlink,
                  !node.isVirtual,
                  node.logicalSize >= minSize else { continue }

            let size = node.logicalSize
            let inode = node.inode

            if excludeHardLinks && inode > 0 {
                if seenInodes[size, default: []].contains(inode) { continue }
                seenInodes[size, default: []].insert(inode)
            }

            sizeMap[size, default: []].append((index: UInt32(i), inode: inode))
        }

        return sizeMap.filter { $0.value.count > 1 }
    }
}
