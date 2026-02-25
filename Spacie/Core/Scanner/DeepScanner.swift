import Foundation

// MARK: - DeepScanEvent

/// Events emitted by ``DeepScanner`` during Phase 2 (deep scanning).
///
/// These events wrap the underlying ``DiskScanner`` output and add
/// directory-level progress tracking so the orchestrator can update
/// the visualization incrementally.
enum DeepScanEvent: Sendable {
    /// A file or directory node found during deep scanning.
    case fileFound(node: RawFileNode)
    /// A directory's deep scan is complete.
    case directoryCompleted(path: String, dirIndex: Int, totalDirs: Int)
    /// Progress update with current Phase 2 stats.
    case progress(ScanProgress)
    /// A restricted directory was encountered.
    case restricted(path: String)
    /// An error occurred during scanning.
    case error(path: String, code: Int32, message: String)
    /// All directories have been fully scanned.
    case completed(stats: ScanStats)
    /// Smart Scan coverage threshold has been reached; scanning can stop early.
    case smartThresholdReached(coverage: Double, scannedBytes: UInt64)
}

// MARK: - ParallelScanState

/// Thread-safe shared state for parallel directory scanning in DeepScanner.
///
/// Manages a work queue of directories, aggregate counters, and Smart Scan
/// coverage tracking. All mutable state is protected by `os_unfair_lock`.
final class ParallelScanState: @unchecked Sendable {
    private var _lock = os_unfair_lock()

    let directories: [(path: String, entryCount: UInt32)]
    let totalDirCount: Int
    private var nextIndex: Int = 0

    // Smart scan state
    private var completedPaths = Set<String>()
    let isSmartScan: Bool
    let threshold: Double
    let tier1Paths: Set<String>
    let estimatedUsedSpace: UInt64
    private(set) var thresholdReached = false

    // Aggregate counters
    private(set) var totalFilesScanned: UInt64 = 0
    private(set) var totalDirsScanned: UInt64 = 0
    private(set) var totalLogicalSize: UInt64 = 0
    private(set) var totalPhysicalSize: UInt64 = 0
    private(set) var totalRestricted: UInt64 = 0
    private(set) var totalSkipped: UInt64 = 0
    private(set) var dirsCompleted: UInt64 = 0

    init(
        directories: [(path: String, entryCount: UInt32)],
        smartScanSettings: SmartScanSettings?,
        estimatedUsedSpace: UInt64,
        tier1Paths: Set<String>?
    ) {
        self.directories = directories
        self.totalDirCount = directories.count
        self.threshold = smartScanSettings?.coverageThreshold ?? 1.0
        self.isSmartScan = smartScanSettings != nil && self.threshold < 1.0
        self.tier1Paths = tier1Paths ?? []
        self.estimatedUsedSpace = estimatedUsedSpace
    }

    /// Claims the next unprocessed directory from the queue.
    /// Skips directories already covered by completed parents (Smart Scan).
    /// Returns nil when queue is exhausted or threshold reached.
    func claimNextDirectory() -> (index: Int, info: (path: String, entryCount: UInt32))? {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        if thresholdReached { return nil }

        while nextIndex < directories.count {
            let idx = nextIndex
            nextIndex += 1
            let dirInfo = directories[idx]

            // Smart Scan: skip if already covered by a completed parent
            if isSmartScan && SmartScanPrioritizer.shouldSkipDirectory(dirInfo.path, completedPaths: completedPaths) {
                continue
            }
            return (idx, dirInfo)
        }
        return nil
    }

    /// Builds scoped exclusion rules for a directory, handling Tier 1/Tier 2 differences.
    func buildScopedExclusionRules(
        for dirPath: String,
        baseRules: ScanExclusionRules
    ) -> ScanExclusionRules {
        if !isSmartScan { return baseRules }

        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        let isTier1 = tier1Paths.contains(dirPath)
        if isTier1 {
            let filteredPrefixes = baseRules.excludedPathPrefixes.filter { prefix in
                !(dirPath == prefix || dirPath.hasPrefix(prefix + "/"))
            }
            return ScanExclusionRules(
                excludedBasenames: baseRules.excludedBasenames,
                excludedPathPrefixes: filteredPrefixes
            )
        } else {
            let dirWithSlash = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
            let childExclusions = completedPaths.filter { completedPath in
                let completedWithSlash = completedPath.hasSuffix("/") ? completedPath : completedPath + "/"
                return completedWithSlash.hasPrefix(dirWithSlash)
            }
            let augmentedPrefixes = baseRules.excludedPathPrefixes + Array(childExclusions)
            return ScanExclusionRules(
                excludedBasenames: baseRules.excludedBasenames,
                excludedPathPrefixes: augmentedPrefixes
            )
        }
    }

    /// Records completion of a directory scan and checks Smart Scan threshold.
    /// Returns (coverage, shouldStop) tuple.
    func completeDirectory(path: String, stats: ScanStats) -> (coverage: Double?, shouldStop: Bool) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }

        completedPaths.insert(path)
        totalFilesScanned &+= stats.totalFiles
        totalDirsScanned &+= stats.totalDirectories
        totalLogicalSize &+= stats.totalLogicalSize
        totalPhysicalSize &+= stats.totalPhysicalSize
        totalRestricted &+= stats.restrictedDirectories
        totalSkipped &+= stats.skippedDirectories
        dirsCompleted &+= 1

        if isSmartScan && estimatedUsedSpace > 0 {
            let coverage = Double(totalLogicalSize) / Double(estimatedUsedSpace)
            if coverage >= threshold {
                thresholdReached = true
                return (coverage, true)
            }
            return (coverage, false)
        }
        return (nil, false)
    }

    /// Returns a snapshot of current aggregate counters.
    func snapshot() -> (
        files: UInt64, dirs: UInt64, logical: UInt64, physical: UInt64,
        restricted: UInt64, skipped: UInt64, completed: UInt64
    ) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return (
            totalFilesScanned, totalDirsScanned, totalLogicalSize,
            totalPhysicalSize, totalRestricted, totalSkipped, dirsCompleted
        )
    }

    /// Returns current coverage info for progress reporting.
    func coverageInfo(additionalLogical: UInt64 = 0) -> (coverage: Double?, scannedBytes: UInt64) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        let currentBytes = totalLogicalSize &+ additionalLogical
        let coverage: Double? = isSmartScan && estimatedUsedSpace > 0
            ? Double(currentBytes) / Double(estimatedUsedSpace)
            : nil
        return (coverage, currentBytes)
    }
}

// MARK: - DeepScanner

/// Phase 2 scanner: deep-scans directories in priority order using ``DiskScanner``.
///
/// Takes a list of directories sorted by entry count (descending) from the
/// shallow tree and runs a full ``DiskScanner`` scan for each one. This
/// ensures the largest (most visually impactful) directories are resolved
/// first, providing immediate visual feedback.
///
/// The scanner does **not** build a tree itself. It emits ``DeepScanEvent``
/// values that the caller (``ScanOrchestrator``) uses to populate a deep tree.
///
/// ## Cancellation
/// Checks `Task.isCancelled` between each directory scan and cooperatively
/// stops if the parent task has been cancelled.
///
/// ## Usage
/// ```swift
/// let scanner = DeepScanner()
/// let stream = scanner.scan(
///     directories: sortedDirs,
///     configuration: config
/// )
/// for await event in stream {
///     switch event { ... }
/// }
/// ```
final class DeepScanner: Sendable {

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Scans directories in priority order, emitting events for each file found.
    ///
    /// For each directory in the list, a scoped ``DiskScanner`` is created with
    /// the directory's path as root. All file and directory nodes discovered are
    /// re-emitted as ``DeepScanEvent/fileFound(node:)`` events. Between
    /// directories, a ``DeepScanEvent/directoryCompleted(path:dirIndex:totalDirs:)``
    /// event is emitted so the orchestrator can trigger tree updates.
    ///
    /// - Parameters:
    ///   - directories: Directory paths sorted by priority (heaviest first).
    ///     Each tuple contains the path and the entry count from the shallow scan.
    ///   - configuration: Base scan configuration (for exclusion rules, flags, etc.).
    ///     The `rootPath` field is overridden for each directory.
    /// - Returns: An async stream of deep scan events from all directories.
    func scan(
        directories: [(path: String, entryCount: UInt32)],
        configuration: ScanConfiguration
    ) -> AsyncStream<DeepScanEvent> {
        scan(
            directories: directories,
            configuration: configuration,
            smartScanSettings: nil,
            estimatedUsedSpace: 0,
            smartScanTier1Paths: nil
        )
    }

    /// Scans directories in priority order with optional Smart Scan threshold support.
    ///
    /// When `smartScanSettings` is non-nil and the coverage threshold is less than 1.0,
    /// the scanner tracks cumulative scanned bytes and emits a
    /// ``DeepScanEvent/smartThresholdReached(coverage:scannedBytes:)`` event when coverage
    /// reaches the configured threshold, then stops scanning further directories.
    ///
    /// For Tier 1 paths (from the scan profile), the scanner temporarily removes the path
    /// from exclusion prefixes so that directories otherwise excluded by
    /// ``ScanExclusionManager`` are scanned. For Tier 2 paths, already-completed child
    /// paths are added as additional exclusion prefixes to avoid double-scanning.
    ///
    /// - Parameters:
    ///   - directories: Directory paths sorted by priority (Tier 1 first, then Tier 2).
    ///   - configuration: Base scan configuration (for exclusion rules, flags, etc.).
    ///   - smartScanSettings: Smart Scan settings, or `nil` for a standard full scan.
    ///   - estimatedUsedSpace: Estimated used bytes on the volume (totalSize - freeSize).
    ///   - smartScanTier1Paths: Set of Tier 1 paths from the active profile.
    ///     When a directory matches a Tier 1 path, its own path is removed from exclusion prefixes.
    /// - Returns: An async stream of deep scan events from all directories.
    func scan(
        directories: [(path: String, entryCount: UInt32)],
        configuration: ScanConfiguration,
        smartScanSettings: SmartScanSettings?,
        estimatedUsedSpace: UInt64,
        smartScanTier1Paths: Set<String>?
    ) -> AsyncStream<DeepScanEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.performDeepScan(
                    directories: directories,
                    configuration: configuration,
                    smartScanSettings: smartScanSettings,
                    estimatedUsedSpace: estimatedUsedSpace,
                    smartScanTier1Paths: smartScanTier1Paths,
                    continuation: continuation
                )
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Core Scan Implementation

    /// Scans directories in parallel using ``BulkDiskScanner`` with a work-stealing queue.
    ///
    /// Spawns up to `min(6, activeProcessorCount)` concurrent worker tasks, each of
    /// which repeatedly claims the next unprocessed directory from ``ParallelScanState``
    /// and runs a full ``BulkDiskScanner`` scan. Results are forwarded to the continuation
    /// as ``DeepScanEvent`` values.
    ///
    /// When Smart Scan is active, completed paths are tracked in shared state to avoid
    /// double-scanning, and workers stop once the coverage threshold is reached.
    private static func performDeepScan(
        directories: [(path: String, entryCount: UInt32)],
        configuration: ScanConfiguration,
        smartScanSettings: SmartScanSettings?,
        estimatedUsedSpace: UInt64,
        smartScanTier1Paths: Set<String>?,
        continuation: AsyncStream<DeepScanEvent>.Continuation
    ) async {
        let totalDirs = directories.count
        let startTime = ContinuousClock.now

        let state = ParallelScanState(
            directories: directories,
            smartScanSettings: smartScanSettings,
            estimatedUsedSpace: estimatedUsedSpace,
            tier1Paths: smartScanTier1Paths
        )

        let concurrency = min(6, ProcessInfo.processInfo.activeProcessorCount)

        // --- Parallel directory scanning ---
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask {
                    while let claimed = state.claimNextDirectory() {
                        if Task.isCancelled { break }

                        let dirIndex = claimed.index
                        let dirInfo = claimed.info
                        let dirPath = dirInfo.path
                        let dirURL = URL(filePath: dirPath)

                        // Build scoped exclusion rules (thread-safe)
                        let scopedExclusionRules = state.buildScopedExclusionRules(
                            for: dirPath,
                            baseRules: configuration.exclusionRules
                        )

                        let scopedConfig = ScanConfiguration(
                            rootPath: dirURL,
                            volumeId: configuration.volumeId,
                            followSymlinks: configuration.followSymlinks,
                            crossMountPoints: configuration.crossMountPoints,
                            includeHidden: configuration.includeHidden,
                            batchSize: configuration.batchSize,
                            throttleInterval: configuration.throttleInterval,
                            exclusionRules: scopedExclusionRules
                        )

                        // Use BulkDiskScanner for performance
                        let scanner = BulkDiskScanner()
                        let scanStream = scanner.scan(configuration: scopedConfig)

                        for await event in scanStream {
                            if Task.isCancelled { break }
                            if state.thresholdReached { break }

                            switch event {
                            case .fileFound(let node):
                                continuation.yield(.fileFound(node: node))

                            case .progress(let progress):
                                let snap = state.snapshot()
                                let now = ContinuousClock.now
                                let totalElapsed = now - startTime
                                let elapsedSeconds = Double(totalElapsed.components.seconds)
                                    + Double(totalElapsed.components.attoseconds) / 1e18

                                let deepProgress = totalDirs > 0
                                    ? (Double(snap.completed) + Double(progress.filesScanned) / max(1.0, Double(dirInfo.entryCount))) / Double(totalDirs)
                                    : 0.0

                                let currentScannedBytes = snap.logical &+ progress.totalLogicalSizeScanned
                                let currentCoverage: Double? = state.isSmartScan && estimatedUsedSpace > 0
                                    ? Double(currentScannedBytes) / Double(estimatedUsedSpace)
                                    : nil

                                continuation.yield(.progress(ScanProgress(
                                    filesScanned: snap.files &+ progress.filesScanned,
                                    directoriesScanned: snap.dirs &+ progress.directoriesScanned,
                                    skippedDirectories: snap.skipped &+ progress.skippedDirectories,
                                    totalLogicalSizeScanned: snap.logical &+ progress.totalLogicalSizeScanned,
                                    totalPhysicalSizeScanned: snap.physical &+ progress.totalPhysicalSizeScanned,
                                    currentPath: progress.currentPath,
                                    elapsedTime: elapsedSeconds,
                                    estimatedTotalFiles: nil,
                                    phase: .yellow,
                                    deepScanProgress: min(1.0, deepProgress),
                                    deepScanDirsCompleted: snap.completed,
                                    deepScanDirsTotal: UInt64(totalDirs),
                                    coveragePercent: currentCoverage,
                                    scannedBytes: currentScannedBytes,
                                    estimatedUsedSpace: estimatedUsedSpace
                                )))

                            case .restricted(let path):
                                continuation.yield(.restricted(path: path))

                            case .error(let path, let code, let message):
                                continuation.yield(.error(path: path, code: code, message: message))

                            case .completed(let stats):
                                // Record completion in shared state
                                let (coverage, shouldStop) = state.completeDirectory(
                                    path: dirPath,
                                    stats: stats
                                )

                                // Emit directory completed event
                                continuation.yield(.directoryCompleted(
                                    path: dirPath,
                                    dirIndex: dirIndex,
                                    totalDirs: totalDirs
                                ))

                                // Emit progress after directory completes
                                let snap = state.snapshot()
                                let now = ContinuousClock.now
                                let totalElapsed = now - startTime
                                let elapsedSeconds = Double(totalElapsed.components.seconds)
                                    + Double(totalElapsed.components.attoseconds) / 1e18

                                let deepProgress = Double(snap.completed) / Double(max(1, totalDirs))

                                continuation.yield(.progress(ScanProgress(
                                    filesScanned: snap.files,
                                    directoriesScanned: snap.dirs,
                                    skippedDirectories: snap.skipped,
                                    totalLogicalSizeScanned: snap.logical,
                                    totalPhysicalSizeScanned: snap.physical,
                                    currentPath: dirPath,
                                    elapsedTime: elapsedSeconds,
                                    estimatedTotalFiles: nil,
                                    phase: .yellow,
                                    deepScanProgress: min(1.0, deepProgress),
                                    deepScanDirsCompleted: snap.completed,
                                    deepScanDirsTotal: UInt64(totalDirs),
                                    coveragePercent: coverage,
                                    scannedBytes: snap.logical,
                                    estimatedUsedSpace: estimatedUsedSpace
                                )))

                                // Smart Scan threshold check
                                if shouldStop {
                                    continuation.yield(.smartThresholdReached(
                                        coverage: coverage ?? 0.0,
                                        scannedBytes: snap.logical
                                    ))
                                }

                            case .directoryEntered, .directoryCompleted, .directorySkipped:
                                break
                            }
                        }

                        // If threshold reached, stop this worker
                        if state.thresholdReached { break }
                    }
                }
            }
            // All workers complete here (or cancelled)
        }

        // --- Final completion ---
        let snap = state.snapshot()
        let totalDuration = ContinuousClock.now - startTime
        let durationSeconds = Double(totalDuration.components.seconds)
            + Double(totalDuration.components.attoseconds) / 1e18

        continuation.yield(.completed(stats: ScanStats(
            totalFiles: snap.files,
            totalDirectories: snap.dirs,
            totalLogicalSize: snap.logical,
            totalPhysicalSize: snap.physical,
            restrictedDirectories: snap.restricted,
            skippedDirectories: snap.skipped,
            scanDuration: durationSeconds,
            volumeId: configuration.volumeId
        )))
    }
}
