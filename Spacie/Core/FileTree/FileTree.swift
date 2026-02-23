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
    private let lock = NSLock()

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
            inode: 0
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
        lock.lock()
        defer { lock.unlock() }

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
            inode: raw.inode
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
        if let lastSlash = path.lastIndex(of: "/"), lastSlash != path.startIndex {
            parentOfParent = String(path[path.startIndex..<lastSlash])
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
        if let lastSlash = path.lastIndex(of: "/") {
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
            inode: 0
        )

        // Link to grandparent
        if grandparentIdx > 0 && Int(grandparentIdx) < nodes.count {
            placeholder.nextSiblingIndex = nodes[Int(grandparentIdx)].firstChildIndex
            nodes[Int(grandparentIdx)].firstChildIndex = newIndex
            nodes[Int(grandparentIdx)].childCount &+= 1
        }

        nodes.append(placeholder)
        pathIndex[path] = newIndex

        return newIndex
    }

    /// Aggregates sizes from leaf nodes up to the root.
    ///
    /// Must be called after all nodes have been inserted and before
    /// ``finalizeBuild()``. Walks the tree bottom-up, summing child sizes
    /// into their parent directories.
    func aggregateSizes() {
        lock.lock()
        defer { lock.unlock() }

        // Process nodes in reverse order. Since children are always inserted
        // after their parents (or at higher indices due to post-order), iterating
        // backwards naturally processes children before parents.
        let count = nodes.count
        for i in stride(from: count - 1, through: 1, by: -1) {
            let parentIdx = Int(nodes[i].parentIndex)
            guard parentIdx > 0, parentIdx < count else { continue }

            nodes[parentIdx].logicalSize &+= nodes[i].logicalSize
            nodes[parentIdx].physicalSize &+= nodes[i].physicalSize
        }
    }

    /// Finalizes the build phase, releasing the path index to reclaim memory.
    ///
    /// After this call, no further insertions are allowed and the tree
    /// becomes safe for concurrent reads.
    func finalizeBuild() {
        lock.lock()
        defer { lock.unlock() }

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
                flags: []
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
            depth: depth,
            flags: node.flags
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
        candidates.reserveCapacity(min(count * 2, nodes.count))

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

    // MARK: - Subscript Access

    /// Provides direct subscript access to the underlying ``FileNode`` at the given index.
    ///
    /// - Parameter index: The node index (0-based into the flat array).
    /// - Returns: The ``FileNode`` at that index.
    /// - Note: Index 0 is the sentinel. Valid tree nodes start at index 1.
    subscript(_ index: UInt32) -> FileNode {
        nodes[Int(index)]
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
