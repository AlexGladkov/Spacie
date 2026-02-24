import XCTest
@testable import Spacie

// MARK: - ScannerSizeInvariantTests

/// Validates critical size invariants for BulkDiskScanner, DiskScanner,
/// FileTree, and ParallelScanState.
///
/// These tests ensure that scanned sizes are consistent, never exceed
/// disk reality, and that concurrent operations preserve correctness.
final class ScannerSizeInvariantTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: URL!

    // MARK: - Lifecycle

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpacieTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Creates a file with exactly `size` bytes of content.
    private func createFile(at path: String, size: Int) throws {
        let data = Data(repeating: 0xAA, count: size)
        try data.write(to: URL(filePath: path))
    }

    /// Returns a ``ScanConfiguration`` pointing at `tempDir` with no exclusions.
    private func makeConfig() -> ScanConfiguration {
        ScanConfiguration(
            rootPath: tempDir,
            volumeId: "test-volume",
            followSymlinks: false,
            crossMountPoints: false,
            includeHidden: true,
            batchSize: 1000,
            throttleInterval: 0.0,
            exclusionRules: ScanExclusionRules(
                excludedBasenames: [],
                excludedPathPrefixes: []
            )
        )
    }

    /// Simulates the DeepScanner pattern: scans root directory with
    /// ``BulkDiskScanner`` (single-level), then scans each discovered
    /// subdirectory the same way. Returns aggregated events and a
    /// synthetic `.completed` with combined stats.
    private func collectBulkScanEvents() async -> [ScanEvent] {
        var allFileNodes: [RawFileNode] = []
        var totalFiles: UInt64 = 0
        var totalDirs: UInt64 = 0
        var totalLogical: UInt64 = 0
        var totalPhysical: UInt64 = 0
        var totalRestricted: UInt64 = 0
        var totalSkipped: UInt64 = 0

        var dirsToScan: [URL] = [tempDir]
        var scannedDirs = Set<String>()

        while !dirsToScan.isEmpty {
            let dir = dirsToScan.removeFirst()
            let dirPath = dir.path(percentEncoded: false)
            guard scannedDirs.insert(dirPath).inserted else { continue }

            let config = ScanConfiguration(
                rootPath: dir,
                volumeId: "test-volume",
                followSymlinks: false,
                crossMountPoints: false,
                includeHidden: true,
                batchSize: 1000,
                throttleInterval: 0.0,
                exclusionRules: ScanExclusionRules(
                    excludedBasenames: [],
                    excludedPathPrefixes: []
                )
            )
            let scanner = BulkDiskScanner()
            for await event in scanner.scan(configuration: config) {
                switch event {
                case .fileFound(let node):
                    allFileNodes.append(node)
                    if node.flags.contains(.isDirectory)
                        && !node.flags.contains(.isExcluded)
                        && !node.flags.contains(.isRestricted) {
                        dirsToScan.append(URL(filePath: node.path))
                    }
                case .completed(let stats):
                    totalFiles &+= stats.totalFiles
                    totalDirs &+= stats.totalDirectories
                    totalLogical &+= stats.totalLogicalSize
                    totalPhysical &+= stats.totalPhysicalSize
                    totalRestricted &+= stats.restrictedDirectories
                    totalSkipped &+= stats.skippedDirectories
                default:
                    break
                }
            }
        }

        // Build aggregated events
        var events: [ScanEvent] = allFileNodes.map { .fileFound(node: $0) }
        events.append(.completed(stats: ScanStats(
            totalFiles: totalFiles,
            totalDirectories: totalDirs,
            totalLogicalSize: totalLogical,
            totalPhysicalSize: totalPhysical,
            restrictedDirectories: totalRestricted,
            skippedDirectories: totalSkipped,
            scanDuration: 0.0,
            volumeId: "test-volume"
        )))
        return events
    }

    /// Consumes a ``DiskScanner`` stream and returns all events.
    private func collectDiskScanEvents() async -> [ScanEvent] {
        let scanner = DiskScanner()
        let stream = scanner.scan(configuration: makeConfig())
        var events: [ScanEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    /// Extracts the ``ScanStats`` from a list of scan events.
    private func extractStats(from events: [ScanEvent]) -> ScanStats? {
        for event in events {
            if case .completed(let stats) = event {
                return stats
            }
        }
        return nil
    }

    /// Extracts all ``RawFileNode`` values from `.fileFound` events.
    private func extractFileNodes(from events: [ScanEvent]) -> [RawFileNode] {
        events.compactMap { event in
            if case .fileFound(let node) = event {
                return node
            }
            return nil
        }
    }

    // MARK: - Group 1: Real Filesystem Scan Invariants

    /// Verifies that BulkDiskScanner reports the correct total logical size
    /// and file/directory counts for a known directory structure.
    ///
    /// Creates: dir/a.txt (1000 bytes), dir/b.txt (2000 bytes), dir/sub/c.txt (3000 bytes).
    /// Expected: totalLogicalSize == 6000, totalFiles == 3, totalDirectories >= 2.
    func testBulkScannerTotalSizeMatchesActualFiles() async throws {
        // Arrange
        let subDir = tempDir.appending(path: "sub")
        try FileManager.default.createDirectory(
            at: subDir,
            withIntermediateDirectories: true
        )

        try createFile(at: tempDir.appending(path: "a.txt").path, size: 1000)
        try createFile(at: tempDir.appending(path: "b.txt").path, size: 2000)
        try createFile(at: subDir.appending(path: "c.txt").path, size: 3000)

        // Act
        let events = await collectBulkScanEvents()
        let stats = extractStats(from: events)

        // Assert
        XCTAssertNotNil(stats, "Scanner must emit a .completed event with stats")
        guard let stats else { return }

        XCTAssertEqual(
            stats.totalLogicalSize, 6000,
            "Total logical size must equal sum of all created files (1000 + 2000 + 3000)"
        )
        XCTAssertEqual(
            stats.totalFiles, 3,
            "Scanner must report exactly 3 files"
        )
        XCTAssertGreaterThanOrEqual(
            stats.totalDirectories, 2,
            "Scanner must report at least 2 directories (root + sub)"
        )
    }

    /// Verifies the critical invariant: total scanned size must never exceed
    /// the actual disk usage of the scanned directory.
    ///
    /// Uses `stat()` to obtain actual on-disk sizes and compares against
    /// scanner-reported values with a generous margin for directory metadata.
    func testBulkScannerSizeNeverExceedsDiskSize() async throws {
        // Arrange: create files with known sizes
        let subDir = tempDir.appending(path: "nested")
        try FileManager.default.createDirectory(
            at: subDir,
            withIntermediateDirectories: true
        )

        try createFile(at: tempDir.appending(path: "file1.dat").path, size: 4096)
        try createFile(at: tempDir.appending(path: "file2.dat").path, size: 8192)
        try createFile(at: subDir.appending(path: "file3.dat").path, size: 16384)

        let expectedLogicalTotal: UInt64 = 4096 + 8192 + 16384

        // Get actual disk usage via stat for each file
        var actualPhysicalUsage: UInt64 = 0
        let filePaths = [
            tempDir.appending(path: "file1.dat").path,
            tempDir.appending(path: "file2.dat").path,
            subDir.appending(path: "file3.dat").path,
        ]
        for filePath in filePaths {
            var fileStat = stat()
            XCTAssertEqual(lstat(filePath, &fileStat), 0, "stat() must succeed for \(filePath)")
            actualPhysicalUsage += UInt64(fileStat.st_blocks) * 512
        }

        // Act
        let events = await collectBulkScanEvents()
        let stats = extractStats(from: events)

        // Assert
        XCTAssertNotNil(stats)
        guard let stats else { return }

        // Logical size must equal exactly what we wrote
        XCTAssertEqual(
            stats.totalLogicalSize, expectedLogicalTotal,
            "Logical size must match sum of created file sizes"
        )

        // Physical size must not exceed actual disk usage plus a margin
        // for directory metadata (4 KB per directory is generous)
        let metadataMargin: UInt64 = 4096 * 10
        XCTAssertLessThanOrEqual(
            stats.totalPhysicalSize,
            actualPhysicalUsage + metadataMargin,
            "Physical size (\(stats.totalPhysicalSize)) must not exceed actual disk usage (\(actualPhysicalUsage)) plus metadata margin"
        )
    }

    /// Verifies that BulkDiskScanner and DiskScanner produce identical
    /// aggregate statistics for the same directory tree.
    func testBulkScannerMatchesDiskScanner() async throws {
        // Arrange
        let sub1 = tempDir.appending(path: "alpha")
        let sub2 = tempDir.appending(path: "alpha/beta")
        try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

        try createFile(at: tempDir.appending(path: "root.txt").path, size: 500)
        try createFile(at: sub1.appending(path: "mid.txt").path, size: 1500)
        try createFile(at: sub2.appending(path: "deep.txt").path, size: 2500)

        // Act
        let bulkEvents = await collectBulkScanEvents()
        let diskEvents = await collectDiskScanEvents()

        let bulkStats = extractStats(from: bulkEvents)
        let diskStats = extractStats(from: diskEvents)

        // Assert
        XCTAssertNotNil(bulkStats, "BulkDiskScanner must emit completion stats")
        XCTAssertNotNil(diskStats, "DiskScanner must emit completion stats")
        guard let bulkStats, let diskStats else { return }

        XCTAssertEqual(
            bulkStats.totalFiles, diskStats.totalFiles,
            "File count must match between BulkDiskScanner (\(bulkStats.totalFiles)) and DiskScanner (\(diskStats.totalFiles))"
        )
        XCTAssertEqual(
            bulkStats.totalDirectories, diskStats.totalDirectories,
            "Directory count must match between BulkDiskScanner (\(bulkStats.totalDirectories)) and DiskScanner (\(diskStats.totalDirectories))"
        )
        XCTAssertEqual(
            bulkStats.totalLogicalSize, diskStats.totalLogicalSize,
            "Logical size must match between BulkDiskScanner (\(bulkStats.totalLogicalSize)) and DiskScanner (\(diskStats.totalLogicalSize))"
        )
        XCTAssertEqual(
            bulkStats.totalPhysicalSize, diskStats.totalPhysicalSize,
            "Physical size must match between BulkDiskScanner (\(bulkStats.totalPhysicalSize)) and DiskScanner (\(diskStats.totalPhysicalSize))"
        )
    }

    /// Verifies the FileTree aggregation invariant: after building a tree
    /// from scanner events and aggregating sizes, the root node's logical
    /// size must equal both the sum of all file node sizes and the scanner's
    /// reported totalLogicalSize.
    func testTreeBuiltFromScanNeverExceedsTotalInput() async throws {
        // Arrange
        let sub = tempDir.appending(path: "data")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        try createFile(at: tempDir.appending(path: "x.bin").path, size: 1234)
        try createFile(at: sub.appending(path: "y.bin").path, size: 5678)
        try createFile(at: sub.appending(path: "z.bin").path, size: 9012)

        // Act
        let events = await collectBulkScanEvents()
        let stats = extractStats(from: events)
        let fileNodes = extractFileNodes(from: events)

        XCTAssertNotNil(stats)
        guard let stats else { return }

        // Build FileTree from scanner events
        let tree = FileTree(estimatedNodeCount: fileNodes.count)
        for node in fileNodes {
            tree.insert(node)
        }
        tree.aggregateSizes()
        tree.finalizeBuild()

        // Compute sum of non-directory file logical sizes from events
        let sumOfFileLogicalSizes = fileNodes
            .filter { !$0.flags.contains(.isDirectory) }
            .reduce(UInt64(0)) { $0 + $1.logicalSize }

        let rootLogicalSize = tree.logicalSize(of: tree.rootIndex)

        // Assert
        XCTAssertEqual(
            rootLogicalSize, sumOfFileLogicalSizes,
            "Root logical size (\(rootLogicalSize)) must equal sum of file node sizes (\(sumOfFileLogicalSizes))"
        )
        XCTAssertEqual(
            rootLogicalSize, stats.totalLogicalSize,
            "Root logical size (\(rootLogicalSize)) must equal stats.totalLogicalSize (\(stats.totalLogicalSize))"
        )
        XCTAssertGreaterThan(
            tree.nodeCount, 0,
            "Tree must contain at least one node"
        )
    }

    // MARK: - Group 2: ParallelScanState Coverage Invariants

    /// Verifies that coverage tracks cumulative logical size correctly
    /// and that the threshold triggers at the right point.
    func testCoverageNeverExceedsEstimatedSpace() {
        // Arrange
        let dirs: [(path: String, entryCount: UInt32)] = [
            ("/dir1", 100),
            ("/dir2", 200),
            ("/dir3", 300),
            ("/dir4", 50),
        ]
        let settings = SmartScanSettings(
            isEnabled: true,
            profile: .default,
            coverageThreshold: 0.95
        )
        let state = ParallelScanState(
            directories: dirs,
            smartScanSettings: settings,
            estimatedUsedSpace: 1_000_000,
            tier1Paths: nil
        )

        // Act & Assert: complete directories totaling 900,000 bytes
        let stats1 = ScanStats(
            totalFiles: 50,
            totalDirectories: 5,
            totalLogicalSize: 500_000,
            totalPhysicalSize: 500_000,
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0.1,
            volumeId: "test"
        )
        let (coverage1, shouldStop1) = state.completeDirectory(path: "/dir1", stats: stats1)

        XCTAssertNotNil(coverage1)
        XCTAssertEqual(coverage1!, 0.5, accuracy: 0.001, "Coverage should be 0.5 after 500K / 1M")
        XCTAssertFalse(shouldStop1, "Should not stop at 50% coverage with 95% threshold")

        let stats2 = ScanStats(
            totalFiles: 40,
            totalDirectories: 4,
            totalLogicalSize: 400_000,
            totalPhysicalSize: 400_000,
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0.1,
            volumeId: "test"
        )
        let (coverage2, shouldStop2) = state.completeDirectory(path: "/dir2", stats: stats2)

        XCTAssertNotNil(coverage2)
        XCTAssertEqual(coverage2!, 0.9, accuracy: 0.001, "Coverage should be 0.9 after 900K / 1M")
        XCTAssertFalse(shouldStop2, "Should not stop at 90% coverage with 95% threshold")

        // Add 60,000 more bytes to push past the threshold
        let stats3 = ScanStats(
            totalFiles: 10,
            totalDirectories: 1,
            totalLogicalSize: 60_000,
            totalPhysicalSize: 60_000,
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0.05,
            volumeId: "test"
        )
        let (coverage3, shouldStop3) = state.completeDirectory(path: "/dir3", stats: stats3)

        XCTAssertNotNil(coverage3)
        XCTAssertEqual(coverage3!, 0.96, accuracy: 0.001, "Coverage should be 0.96 after 960K / 1M")
        XCTAssertTrue(shouldStop3, "Should stop at 96% coverage with 95% threshold")
        XCTAssertTrue(state.thresholdReached, "thresholdReached must be true after exceeding threshold")
    }

    /// Verifies that when estimatedUsedSpace is zero, coverage is always nil
    /// and division by zero is avoided.
    func testCoverageWithZeroEstimatedSpace() {
        // Arrange
        let dirs: [(path: String, entryCount: UInt32)] = [
            ("/dir1", 10),
            ("/dir2", 20),
        ]
        let settings = SmartScanSettings(
            isEnabled: true,
            profile: .default,
            coverageThreshold: 0.95
        )
        let state = ParallelScanState(
            directories: dirs,
            smartScanSettings: settings,
            estimatedUsedSpace: 0,
            tier1Paths: nil
        )

        // Act
        let stats = ScanStats(
            totalFiles: 100,
            totalDirectories: 10,
            totalLogicalSize: 999_999,
            totalPhysicalSize: 999_999,
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0.1,
            volumeId: "test"
        )
        let (coverage, shouldStop) = state.completeDirectory(path: "/dir1", stats: stats)

        // Assert
        XCTAssertNil(coverage, "Coverage must be nil when estimatedUsedSpace is zero")
        XCTAssertFalse(shouldStop, "shouldStop must be false when estimatedUsedSpace is zero")
        XCTAssertFalse(state.thresholdReached, "thresholdReached must remain false")
    }

    /// Verifies that once the coverage threshold is reached, no more
    /// directories can be claimed from the work queue.
    func testThresholdStopsNewClaims() {
        // Arrange
        let dirs: [(path: String, entryCount: UInt32)] = [
            ("/dir1", 10),
            ("/dir2", 20),
            ("/dir3", 30),
            ("/dir4", 40),
            ("/dir5", 50),
        ]
        let settings = SmartScanSettings(
            isEnabled: true,
            profile: .default,
            coverageThreshold: 0.5
        )
        let state = ParallelScanState(
            directories: dirs,
            smartScanSettings: settings,
            estimatedUsedSpace: 100,
            tier1Paths: nil
        )

        // Act: claim and complete first directory with 60 bytes (60% > 50% threshold)
        let claimed = state.claimNextDirectory()
        XCTAssertNotNil(claimed, "First claim must succeed")

        let stats = ScanStats(
            totalFiles: 5,
            totalDirectories: 1,
            totalLogicalSize: 60,
            totalPhysicalSize: 60,
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0.01,
            volumeId: "test"
        )
        let (coverage, shouldStop) = state.completeDirectory(path: "/dir1", stats: stats)

        // Assert
        XCTAssertNotNil(coverage)
        XCTAssertEqual(coverage!, 0.6, accuracy: 0.001)
        XCTAssertTrue(shouldStop, "Should stop since 60% > 50% threshold")
        XCTAssertTrue(state.thresholdReached)

        // No more claims should succeed
        let nextClaim = state.claimNextDirectory()
        XCTAssertNil(nextClaim, "claimNextDirectory() must return nil after threshold is reached")
    }

    /// Verifies that concurrent directory claims from multiple tasks
    /// produce no duplicates and cover all directories exactly once.
    func testConcurrentDirectoryClaimsNoDuplicates() async {
        // Arrange: 100 directories, no smart scan (full coverage)
        let dirs: [(path: String, entryCount: UInt32)] = (0..<100).map {
            ("/dir\($0)", UInt32($0 + 1))
        }
        let state = ParallelScanState(
            directories: dirs,
            smartScanSettings: nil,
            estimatedUsedSpace: 0,
            tier1Paths: nil
        )

        // Act: spawn 8 concurrent tasks claiming directories
        let claimedIndices = ClaimedIndicesCollector()

        await withTaskGroup(of: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var localClaimed: [Int] = []
                    while let claimed = state.claimNextDirectory() {
                        localClaimed.append(claimed.index)
                    }
                    return localClaimed
                }
            }

            for await indices in group {
                claimedIndices.append(indices)
            }
        }

        let allIndices = claimedIndices.allIndices

        // Assert
        let uniqueIndices = Set(allIndices)
        XCTAssertEqual(
            uniqueIndices.count, allIndices.count,
            "No duplicate claims allowed. Got \(allIndices.count) claims but only \(uniqueIndices.count) unique"
        )
        XCTAssertEqual(
            uniqueIndices.count, 100,
            "All 100 directories must be claimed. Got \(uniqueIndices.count)"
        )
    }

    /// Verifies that snapshot() accurately reflects the sum of all
    /// completed directory stats.
    func testSnapshotReflectsCompletions() {
        // Arrange
        let dirs: [(path: String, entryCount: UInt32)] = [
            ("/a", 10),
            ("/b", 20),
            ("/c", 30),
        ]
        let state = ParallelScanState(
            directories: dirs,
            smartScanSettings: nil,
            estimatedUsedSpace: 0,
            tier1Paths: nil
        )

        // Act: complete 3 directories with known stats
        let statsEntries: [(path: String, files: UInt64, dirs: UInt64, logical: UInt64, physical: UInt64, restricted: UInt64, skipped: UInt64)] = [
            ("/a", 10, 2, 1000, 2000, 1, 0),
            ("/b", 20, 3, 3000, 4000, 0, 1),
            ("/c", 5, 1, 500, 800, 0, 0),
        ]

        for entry in statsEntries {
            let stats = ScanStats(
                totalFiles: entry.files,
                totalDirectories: entry.dirs,
                totalLogicalSize: entry.logical,
                totalPhysicalSize: entry.physical,
                restrictedDirectories: entry.restricted,
                skippedDirectories: entry.skipped,
                scanDuration: 0.01,
                volumeId: "test"
            )
            _ = state.completeDirectory(path: entry.path, stats: stats)
        }

        // Assert
        let snap = state.snapshot()
        XCTAssertEqual(snap.files, 35, "Total files: 10 + 20 + 5 = 35")
        XCTAssertEqual(snap.dirs, 6, "Total dirs: 2 + 3 + 1 = 6")
        XCTAssertEqual(snap.logical, 4500, "Total logical: 1000 + 3000 + 500 = 4500")
        XCTAssertEqual(snap.physical, 6800, "Total physical: 2000 + 4000 + 800 = 6800")
        XCTAssertEqual(snap.restricted, 1, "Total restricted: 1 + 0 + 0 = 1")
        XCTAssertEqual(snap.skipped, 1, "Total skipped: 0 + 1 + 0 = 1")
        XCTAssertEqual(snap.completed, 3, "Completed directories: 3")
    }

    // MARK: - Group 3: Hard Link Dedup in Scanner Output

    /// Verifies that a hard-linked file is only counted once in the scanner's
    /// total logical size, preventing inflated disk usage reporting.
    func testHardLinksCountedOnceInBulkScanner() async throws {
        // Arrange
        let originalPath = tempDir.appending(path: "original.dat").path
        let linkPath = tempDir.appending(path: "hardlink.dat").path

        try createFile(at: originalPath, size: 4096)

        // Create a hard link
        let linkResult = link(originalPath, linkPath)
        guard linkResult == 0 else {
            XCTFail("Failed to create hard link: \(String(cString: strerror(errno)))")
            return
        }

        // Verify the hard link was created correctly
        var origStat = stat()
        var linkStat = stat()
        lstat(originalPath, &origStat)
        lstat(linkPath, &linkStat)
        XCTAssertEqual(origStat.st_ino, linkStat.st_ino, "Hard links must share the same inode")
        XCTAssertEqual(origStat.st_nlink, 2, "Link count must be 2 after creating hard link")

        // Act
        let events = await collectBulkScanEvents()
        let stats = extractStats(from: events)
        let fileNodes = extractFileNodes(from: events)

        // Assert
        XCTAssertNotNil(stats)
        guard let stats else { return }

        // The scanner should count the file size only once
        XCTAssertEqual(
            stats.totalLogicalSize, 4096,
            "Total logical size must be 4096 (file counted once), not \(stats.totalLogicalSize)"
        )

        // Among file-found events for regular files, exactly one should have
        // non-zero logicalSize for this inode
        let regularFileNodes = fileNodes.filter {
            !$0.flags.contains(.isDirectory)
            && !$0.flags.contains(.isSymlink)
        }
        let nodesWithSize = regularFileNodes.filter { $0.logicalSize > 0 }
        let nodesWithZeroSize = regularFileNodes.filter { $0.logicalSize == 0 }

        XCTAssertEqual(
            nodesWithSize.count, 1,
            "Exactly one hard-linked file node should have non-zero logicalSize"
        )
        XCTAssertEqual(
            nodesWithZeroSize.count, 1,
            "The second hard link should have zero logicalSize (deduped)"
        )
        XCTAssertEqual(
            stats.totalFiles, 2,
            "Both hard link entries should be counted as files"
        )
    }
}

// MARK: - Thread-Safe Index Collector

/// Thread-safe collector for indices claimed by concurrent tasks.
/// Uses `os_unfair_lock` for minimal overhead, matching the project's
/// concurrency patterns.
private final class ClaimedIndicesCollector: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _indices: [Int] = []

    func append(_ indices: [Int]) {
        os_unfair_lock_lock(&_lock)
        _indices.append(contentsOf: indices)
        os_unfair_lock_unlock(&_lock)
    }

    var allIndices: [Int] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return _indices
    }
}
