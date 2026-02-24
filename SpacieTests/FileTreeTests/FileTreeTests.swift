import XCTest
@testable import Spacie

final class FileTreeTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a `RawFileNode` representing a regular file.
    private func makeFile(
        name: String,
        path: String,
        parentPath: String,
        logicalSize: UInt64,
        physicalSize: UInt64 = 0,
        inode: UInt64 = 0,
        depth: Int = 1,
        flags: FileNodeFlags = [],
        fileType: FileType = .other
    ) -> RawFileNode {
        RawFileNode(
            name: name,
            path: path,
            logicalSize: logicalSize,
            physicalSize: physicalSize,
            flags: flags,
            fileType: fileType,
            modTime: 0,
            inode: inode,
            depth: depth,
            parentPath: parentPath
        )
    }

    /// Creates a `RawFileNode` representing a directory.
    private func makeDir(
        name: String,
        path: String,
        parentPath: String,
        depth: Int = 0
    ) -> RawFileNode {
        RawFileNode(
            name: name,
            path: path,
            logicalSize: 0,
            physicalSize: 0,
            flags: [.isDirectory],
            fileType: .other,
            modTime: 0,
            inode: 0,
            depth: depth,
            parentPath: parentPath
        )
    }

    // MARK: - 1. testSingleInsert

    /// Verifies that inserting a root directory and a child file works correctly,
    /// and that nodeCount, names, and sizes are retrievable.
    func testSingleInsert() {
        let tree = FileTree(estimatedNodeCount: 16)

        let root = makeDir(name: "Root", path: "/Root", parentPath: "", depth: 0)
        let file = makeFile(
            name: "readme.txt",
            path: "/Root/readme.txt",
            parentPath: "/Root",
            logicalSize: 512,
            physicalSize: 4096,
            depth: 1
        )

        let rootIdx = tree.insert(root)
        let fileIdx = tree.insert(file)

        XCTAssertNotNil(rootIdx, "Root insertion must return a valid index")
        XCTAssertNotNil(fileIdx, "File insertion must return a valid index")
        XCTAssertEqual(tree.nodeCount, 2, "Tree must contain exactly 2 nodes (root + file)")

        XCTAssertEqual(tree.name(of: rootIdx!), "Root")
        XCTAssertEqual(tree.name(of: fileIdx!), "readme.txt")

        XCTAssertEqual(tree.logicalSize(of: fileIdx!), 512)
        XCTAssertEqual(tree.physicalSize(of: fileIdx!), 4096)
    }

    // MARK: - 2. testBatchInsertMatchesSingleInsert

    /// Verifies that inserting nodes one-by-one and via `insertBatch` produce
    /// equivalent trees with the same nodeCount and root logicalSize after aggregation.
    func testBatchInsertMatchesSingleInsert() {
        let root = makeDir(name: "Root", path: "/Root", parentPath: "", depth: 0)
        let fileA = makeFile(name: "a.bin", path: "/Root/a.bin", parentPath: "/Root", logicalSize: 100, physicalSize: 100)
        let fileB = makeFile(name: "b.bin", path: "/Root/b.bin", parentPath: "/Root", logicalSize: 250, physicalSize: 250)
        let fileC = makeFile(name: "c.bin", path: "/Root/c.bin", parentPath: "/Root", logicalSize: 650, physicalSize: 650)

        // Tree A: single inserts
        let treeA = FileTree(estimatedNodeCount: 16)
        treeA.insert(root)
        treeA.insert(fileA)
        treeA.insert(fileB)
        treeA.insert(fileC)
        treeA.aggregateSizes()

        // Tree B: batch insert
        let treeB = FileTree(estimatedNodeCount: 16)
        treeB.insertBatch([root, fileA, fileB, fileC])
        treeB.aggregateSizes()

        XCTAssertEqual(treeA.nodeCount, treeB.nodeCount, "Both trees must have the same node count")
        XCTAssertEqual(
            treeA.logicalSize(of: treeA.rootIndex),
            treeB.logicalSize(of: treeB.rootIndex),
            "Root logical sizes must match between single and batch insertion"
        )
    }

    // MARK: - 3. testAggregatedSizeEqualsChildSum

    /// KEY INVARIANT: After `aggregateSizes()`, every directory's logicalSize
    /// must equal the sum of its direct children's logicalSizes.
    ///
    /// Tree structure:
    /// ```
    /// root (expected: 600)
    ///   dir1 (expected: 300)
    ///     file1 (100)
    ///     file2 (200)
    ///   dir2 (expected: 300)
    ///     file3 (300)
    /// ```
    func testAggregatedSizeEqualsChildSum() {
        let tree = FileTree(estimatedNodeCount: 16)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))
        tree.insert(makeDir(name: "dir1", path: "/root/dir1", parentPath: "/root", depth: 1))
        tree.insert(makeDir(name: "dir2", path: "/root/dir2", parentPath: "/root", depth: 1))
        tree.insert(makeFile(name: "file1", path: "/root/dir1/file1", parentPath: "/root/dir1", logicalSize: 100, depth: 2))
        tree.insert(makeFile(name: "file2", path: "/root/dir1/file2", parentPath: "/root/dir1", logicalSize: 200, depth: 2))
        tree.insert(makeFile(name: "file3", path: "/root/dir2/file3", parentPath: "/root/dir2", logicalSize: 300, depth: 2))

        tree.aggregateSizes()

        let rootIdx = tree.rootIndex
        XCTAssertEqual(tree.logicalSize(of: rootIdx), 600, "Root logicalSize must equal sum of all files (600)")

        // Find dir1 and dir2 among root's children
        let rootChildren = tree.children(of: rootIdx)
        XCTAssertEqual(rootChildren.count, 2, "Root must have exactly 2 children (dir1, dir2)")

        for childIdx in rootChildren {
            let childName = tree.name(of: childIdx)
            let childSize = tree.logicalSize(of: childIdx)

            switch childName {
            case "dir1":
                XCTAssertEqual(childSize, 300, "dir1 logicalSize must be 300 (100 + 200)")
                // Verify dir1's children sum matches its size
                let dir1Children = tree.children(of: childIdx)
                let dir1ChildSum = dir1Children.reduce(UInt64(0)) { $0 + tree.logicalSize(of: $1) }
                XCTAssertEqual(childSize, dir1ChildSum, "dir1 size must equal sum of its children")

            case "dir2":
                XCTAssertEqual(childSize, 300, "dir2 logicalSize must be 300")
                let dir2Children = tree.children(of: childIdx)
                let dir2ChildSum = dir2Children.reduce(UInt64(0)) { $0 + tree.logicalSize(of: $1) }
                XCTAssertEqual(childSize, dir2ChildSum, "dir2 size must equal sum of its children")

            default:
                XCTFail("Unexpected child name: \(childName)")
            }
        }
    }

    // MARK: - 4. testAggregatedSizeNeverExceedsTotalInputSize

    /// KEY INVARIANT: The root's aggregated logicalSize must exactly equal
    /// the sum of all individual file sizes inserted (never greater, never less).
    ///
    /// Additionally tests hard link deduplication: when two files share the same
    /// inode and one has size 0 (deduped by the scanner), aggregated size counts once.
    func testAggregatedSizeNeverExceedsTotalInputSize() {
        let tree = FileTree(estimatedNodeCount: 64)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))

        // Insert regular files with known sizes
        let fileSizes: [UInt64] = [100, 200, 300, 400, 500, 1000, 2000, 5000]
        var expectedSum: UInt64 = 0

        for (i, size) in fileSizes.enumerated() {
            let name = "file\(i).dat"
            tree.insert(makeFile(
                name: name,
                path: "/root/\(name)",
                parentPath: "/root",
                logicalSize: size,
                inode: UInt64(i + 1),
                depth: 1
            ))
            expectedSum += size
        }

        tree.aggregateSizes()

        let rootSize = tree.logicalSize(of: tree.rootIndex)
        XCTAssertEqual(rootSize, expectedSum, "Root logicalSize must exactly equal the sum of all file sizes (\(expectedSum))")
        XCTAssertFalse(rootSize > expectedSum, "Root logicalSize must never exceed total input size")

        // Hard link deduplication test:
        // The scanner deduplicates hard links by reporting the second occurrence
        // with size 0. The tree should aggregate faithfully.
        let treeHL = FileTree(estimatedNodeCount: 16)
        treeHL.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))

        // First hard link occurrence: full size
        treeHL.insert(makeFile(
            name: "original.dat",
            path: "/root/original.dat",
            parentPath: "/root",
            logicalSize: 5000,
            physicalSize: 8192,
            inode: 999,
            depth: 1,
            flags: [.isHardLink]
        ))

        // Second hard link occurrence: scanner already deduped to 0
        treeHL.insert(makeFile(
            name: "link.dat",
            path: "/root/link.dat",
            parentPath: "/root",
            logicalSize: 0,
            physicalSize: 0,
            inode: 999,
            depth: 1,
            flags: [.isHardLink]
        ))

        treeHL.aggregateSizes()

        let rootHLSize = treeHL.logicalSize(of: treeHL.rootIndex)
        XCTAssertEqual(rootHLSize, 5000, "Root logicalSize must be 5000 (hard link counted once, deduped by scanner)")
    }

    // MARK: - 5. testHardLinkDeduplicationInTree

    /// Verifies that two hard-linked files with the same inode, where the second
    /// has size 0 (deduped by the scanner), result in correct aggregated root size.
    func testHardLinkDeduplicationInTree() {
        let tree = FileTree(estimatedNodeCount: 16)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))

        // First hard link: reports the real size
        tree.insert(makeFile(
            name: "photo.jpg",
            path: "/root/photo.jpg",
            parentPath: "/root",
            logicalSize: 1000,
            physicalSize: 4096,
            inode: 42,
            depth: 1,
            flags: [.isHardLink]
        ))

        // Second hard link to the same inode: scanner reports 0 to avoid double-counting
        tree.insert(makeFile(
            name: "photo_link.jpg",
            path: "/root/photo_link.jpg",
            parentPath: "/root",
            logicalSize: 0,
            physicalSize: 0,
            inode: 42,
            depth: 1,
            flags: [.isHardLink]
        ))

        tree.aggregateSizes()

        let rootSize = tree.logicalSize(of: tree.rootIndex)
        XCTAssertEqual(rootSize, 1000, "Root size must be 1000 (hard link counted once, not 2000)")

        let rootPhysical = tree.physicalSize(of: tree.rootIndex)
        XCTAssertEqual(rootPhysical, 4096, "Root physical size must be 4096 (hard link physical counted once)")
    }

    // MARK: - 6. testAggregatedPhysicalSizeConsistency

    /// Verifies the same size invariant holds for physical sizes:
    /// root physicalSize must equal the sum of all children's physical sizes.
    func testAggregatedPhysicalSizeConsistency() {
        let tree = FileTree(estimatedNodeCount: 16)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))
        tree.insert(makeDir(name: "sub", path: "/root/sub", parentPath: "/root", depth: 1))

        let files: [(String, UInt64, UInt64)] = [
            ("a.bin", 100, 4096),
            ("b.bin", 200, 4096),
            ("c.bin", 50,  8192),
        ]

        var expectedPhysicalSum: UInt64 = 0
        for (name, logical, physical) in files {
            tree.insert(makeFile(
                name: name,
                path: "/root/sub/\(name)",
                parentPath: "/root/sub",
                logicalSize: logical,
                physicalSize: physical,
                depth: 2
            ))
            expectedPhysicalSum += physical
        }

        tree.aggregateSizes()

        let rootPhysical = tree.physicalSize(of: tree.rootIndex)
        XCTAssertEqual(rootPhysical, expectedPhysicalSum, "Root physicalSize must equal sum of all children's physical sizes (\(expectedPhysicalSum))")

        // Verify intermediate directory as well
        let rootChildren = tree.children(of: tree.rootIndex)
        for childIdx in rootChildren {
            if tree.name(of: childIdx) == "sub" {
                let subPhysical = tree.physicalSize(of: childIdx)
                let subChildrenPhysical = tree.children(of: childIdx)
                    .reduce(UInt64(0)) { $0 + tree.physicalSize(of: $1) }
                XCTAssertEqual(subPhysical, subChildrenPhysical, "Subdirectory physicalSize must equal sum of its children's physical sizes")
            }
        }
    }

    // MARK: - 7. testBatchInsertPreservesParentChild

    /// Verifies that batch insertion correctly establishes parent-child relationships.
    ///
    /// Tree structure:
    /// ```
    /// root
    ///   dirA
    ///     file1
    ///     file2
    /// ```
    func testBatchInsertPreservesParentChild() {
        let tree = FileTree(estimatedNodeCount: 16)

        let nodes: [RawFileNode] = [
            makeDir(name: "root", path: "/root", parentPath: "", depth: 0),
            makeDir(name: "dirA", path: "/root/dirA", parentPath: "/root", depth: 1),
            makeFile(name: "file1.txt", path: "/root/dirA/file1.txt", parentPath: "/root/dirA", logicalSize: 10, depth: 2),
            makeFile(name: "file2.txt", path: "/root/dirA/file2.txt", parentPath: "/root/dirA", logicalSize: 20, depth: 2),
        ]

        tree.insertBatch(nodes)

        // Find dirA among root's children
        let rootChildren = tree.children(of: tree.rootIndex)
        XCTAssertEqual(rootChildren.count, 1, "Root must have exactly 1 child (dirA)")

        guard let dirAIdx = rootChildren.first else {
            XCTFail("Root has no children")
            return
        }
        XCTAssertEqual(tree.name(of: dirAIdx), "dirA")

        // Verify dirA has both files as children
        let dirAChildren = tree.children(of: dirAIdx)
        XCTAssertEqual(dirAChildren.count, 2, "dirA must have exactly 2 children")

        let childNames = Set(dirAChildren.map { tree.name(of: $0) })
        XCTAssertTrue(childNames.contains("file1.txt"), "dirA must contain file1.txt")
        XCTAssertTrue(childNames.contains("file2.txt"), "dirA must contain file2.txt")

        // Verify parent chain: each file's parent should be dirA
        for fileIdx in dirAChildren {
            let parentIdx = tree.node(at: fileIdx)?.parentIndex
            XCTAssertEqual(parentIdx, dirAIdx, "File \(tree.name(of: fileIdx)) must have dirA as parent")
        }
    }

    // MARK: - 8. testAggregationIsIdempotent

    /// Verifies that calling `aggregateSizes()` multiple times produces the
    /// same result (the method resets directory sizes to 0 before re-aggregating).
    func testAggregationIsIdempotent() {
        let tree = FileTree(estimatedNodeCount: 16)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))
        tree.insert(makeDir(name: "sub", path: "/root/sub", parentPath: "/root", depth: 1))
        tree.insert(makeFile(name: "a.bin", path: "/root/sub/a.bin", parentPath: "/root/sub", logicalSize: 1000, physicalSize: 4096, depth: 2))
        tree.insert(makeFile(name: "b.bin", path: "/root/sub/b.bin", parentPath: "/root/sub", logicalSize: 2000, physicalSize: 8192, depth: 2))
        tree.insert(makeFile(name: "c.bin", path: "/root/c.bin", parentPath: "/root", logicalSize: 500, physicalSize: 4096, depth: 1))

        // First aggregation
        tree.aggregateSizes()
        let rootLogical1 = tree.logicalSize(of: tree.rootIndex)
        let rootPhysical1 = tree.physicalSize(of: tree.rootIndex)

        // Second aggregation (must produce identical results)
        tree.aggregateSizes()
        let rootLogical2 = tree.logicalSize(of: tree.rootIndex)
        let rootPhysical2 = tree.physicalSize(of: tree.rootIndex)

        XCTAssertEqual(rootLogical1, rootLogical2, "Logical size must be identical after repeated aggregation")
        XCTAssertEqual(rootPhysical1, rootPhysical2, "Physical size must be identical after repeated aggregation")
        XCTAssertEqual(rootLogical1, 3500, "Root logicalSize must be 3500 (1000 + 2000 + 500)")
        XCTAssertEqual(rootPhysical1, 16384, "Root physicalSize must be 16384 (4096 + 8192 + 4096)")

        // Third aggregation for good measure
        tree.aggregateSizes()
        XCTAssertEqual(tree.logicalSize(of: tree.rootIndex), rootLogical1, "Third aggregation must still match")
    }

    // MARK: - 9. testLargeTreeSizeInvariant

    /// Inserts 10,000 files with pseudo-random sizes and verifies that the
    /// root's aggregated logicalSize exactly equals the tracked sum.
    ///
    /// This tests that no overflow or accumulation error occurs at scale.
    func testLargeTreeSizeInvariant() {
        let fileCount = 10_000
        let tree = FileTree(estimatedNodeCount: fileCount + 10)

        tree.insert(makeDir(name: "root", path: "/root", parentPath: "", depth: 0))

        // Create a few subdirectories to distribute files
        let dirCount = 10
        for d in 0..<dirCount {
            tree.insert(makeDir(
                name: "dir\(d)",
                path: "/root/dir\(d)",
                parentPath: "/root",
                depth: 1
            ))
        }

        // Use a deterministic linear congruential generator for reproducibility
        var rng: UInt64 = 12345
        var trackedLogicalSum: UInt64 = 0
        var trackedPhysicalSum: UInt64 = 0

        for i in 0..<fileCount {
            // Simple LCG: next = (a * current + c) mod m
            rng = (rng &* 6364136223846793005 &+ 1442695040888963407)
            let logicalSize = (rng >> 33) % 1_000_000 + 1 // 1..1_000_000
            let physicalSize = ((logicalSize + 4095) / 4096) * 4096 // round up to 4K blocks

            let dirIndex = i % dirCount
            let name = "file_\(i).dat"

            tree.insert(makeFile(
                name: name,
                path: "/root/dir\(dirIndex)/\(name)",
                parentPath: "/root/dir\(dirIndex)",
                logicalSize: logicalSize,
                physicalSize: physicalSize,
                inode: UInt64(i + 100),
                depth: 2
            ))

            trackedLogicalSum += logicalSize
            trackedPhysicalSum += physicalSize
        }

        tree.aggregateSizes()

        let rootLogical = tree.logicalSize(of: tree.rootIndex)
        let rootPhysical = tree.physicalSize(of: tree.rootIndex)

        XCTAssertEqual(rootLogical, trackedLogicalSum,
                       "Root logicalSize (\(rootLogical)) must exactly equal tracked sum (\(trackedLogicalSum)) for \(fileCount) files")
        XCTAssertEqual(rootPhysical, trackedPhysicalSum,
                       "Root physicalSize (\(rootPhysical)) must exactly equal tracked sum (\(trackedPhysicalSum)) for \(fileCount) files")

        // Also verify individual directory sizes sum to root size
        let rootChildren = tree.children(of: tree.rootIndex)
        let dirLogicalSum = rootChildren.reduce(UInt64(0)) { $0 + tree.logicalSize(of: $1) }
        XCTAssertEqual(dirLogicalSum, rootLogical,
                       "Sum of directory logicalSizes must equal root logicalSize")
    }
}
