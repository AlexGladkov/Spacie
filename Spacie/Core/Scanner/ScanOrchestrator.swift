import Foundation

// MARK: - IncrementalRescanResult

/// Summary of an incremental cache rescan operation.
///
/// Returned by ``ScanOrchestrator/startIncrementalRescan(cachedTree:dirtyPaths:configuration:cache:)``
/// to report what changed during the rescan.
struct IncrementalRescanResult: Sendable {
    /// Number of dirty directories that were successfully rescanned.
    let directoriesRescanned: Int

    /// Net byte change in the root's logical size (positive = growth, negative = shrinkage).
    let bytesChanged: Int64

    /// Wall-clock duration of the entire incremental rescan in seconds.
    let duration: TimeInterval
}

// MARK: - ScanOrchestrator

/// Coordinates a two-phase scan: shallow directory scan followed by deep prioritized file scan.
///
/// **Phase 1 (Red -> Yellow):** Runs ``ShallowScanner`` to build a directory-only tree
/// with entry counts. This completes in ~5-15 seconds and provides immediate structural
/// information for visualization.
///
/// **Phase 2 (Yellow -> Green):** Uses ``DeepScanner`` to process directories in priority
/// order (by entry count descending), running full ``DiskScanner`` passes on each subtree.
/// The deep tree grows incrementally with throttled UI updates.
///
/// **Smart Scan:** When ``smartScanSettings`` is configured, Phase 2 uses
/// ``SmartScanPrioritizer`` to reorder directories (Tier 1 first, Tier 2 by cached size)
/// and stops early once the coverage threshold is reached. A virtual "Other" node is
/// inserted to represent unscanned space. The phase transitions to `.smartGreen` instead
/// of `.green`, and remaining directories are stored for incremental rescan.
///
/// ## Lifecycle
/// ```
/// .red        -- Phase 1 in progress (ShallowScanner)
/// .yellow     -- Phase 1 done, Phase 2 in progress (DeepScanner)
/// .smartGreen -- Coverage threshold reached (partial scan + virtual "Other" node)
/// .green      -- Phase 2 done, all sizes accurate
/// ```
///
/// ## Cancellation
/// Call ``cancel()`` at any time. Both trees are discarded and the scan task is cancelled.
///
/// ## Usage
/// ```swift
/// let orchestrator = ScanOrchestrator()
/// orchestrator.onPhaseChange = { phase in updateUI(phase) }
/// orchestrator.onProgress = { progress in updateProgressBar(progress) }
/// orchestrator.onTreeUpdate = { tree in redrawVisualization(tree) }
///
/// let stats = await orchestrator.startScan(configuration: config)
/// ```
@MainActor
final class ScanOrchestrator {

    // MARK: - State

    /// Current scan phase.
    private(set) var phase: ScanPhase = .red

    /// The shallow tree from Phase 1 (directory-only, entry counts).
    /// Available after Phase 1 completes.
    private(set) var shallowTree: FileTree?

    /// The deep tree being built during Phase 2.
    /// Grows incrementally as directories are scanned.
    private(set) var deepTree: FileTree?

    /// The tree currently used for visualization.
    ///
    /// Returns `nil` during Phase 1 (Red), the shallow tree during Phase 2
    /// (Yellow), and the deep tree once Phase 2 completes (Green).
    var activeTree: FileTree? {
        switch phase {
        case .red: return nil
        case .yellow: return shallowTree
        case .smartGreen: return deepTree
        case .green: return deepTree
        }
    }

    // MARK: - Smart Scan

    /// Smart Scan settings (nil = disabled / full scan).
    var smartScanSettings: SmartScanSettings?

    /// Scan cache for loading/saving directory sizes.
    var scanCache: ScanCache?

    /// Result of the smart scan (coverage, scanned bytes, etc.).
    private(set) var smartScanResult: SmartScanResult?

    /// Directories remaining after smart threshold was reached.
    /// Used for incremental rescan.
    private(set) var remainingDirectories: [(path: String, entryCount: UInt32)] = []

    // MARK: - Callbacks

    /// Callback invoked when the phase changes.
    var onPhaseChange: ((ScanPhase) -> Void)?

    /// Callback invoked periodically with updated progress.
    var onProgress: ((ScanProgress) -> Void)?

    /// Callback invoked when the active tree reference changes (for visualization swap).
    var onTreeUpdate: ((FileTree) -> Void)?

    /// Callback invoked when a restricted directory is encountered.
    var onRestricted: (() -> Void)?

    // MARK: - Internal State

    /// The background task running the scan pipeline.
    private var scanTask: Task<Void, Never>?

    /// The background task running an incremental rescan after deletion.
    private var rescanTask: Task<Void, Never>?

    /// The most recent scan configuration, stored for incremental rescan.
    private var lastConfiguration: ScanConfiguration?

    /// Minimum interval between tree update callbacks during Phase 2.
    private static let treeUpdateThrottleInterval: TimeInterval = 2.0

    // MARK: - Initialization

    init() {}

    // MARK: - Public API

    /// Starts the two-phase scan.
    ///
    /// 1. **Phase 1:** ``ShallowScanner`` builds a directory-only tree. On completion,
    ///    the phase transitions to `.yellow` and `onTreeUpdate` fires with the shallow tree.
    /// 2. **Phase 2:** ``DeepScanner`` processes directories by priority. As directories
    ///    complete, the deep tree is updated and `onTreeUpdate` fires periodically.
    ///    On completion, the phase transitions to `.green` (or `.smartGreen` if smart scan
    ///    reached its coverage threshold).
    ///
    /// - Parameter configuration: Scan parameters including root path, exclusion rules, etc.
    /// - Returns: Final ``ScanStats`` on completion, or `nil` if the scan was cancelled
    ///   or smart scan reached its threshold (results are on ``smartScanResult``).
    func startScan(configuration: ScanConfiguration) async -> ScanStats? {
        // Drain any in-flight scan / rescan before starting new work.
        //
        // Without this await, a rescan click while the previous scan was still
        // winding down would leak the previous Task (overwritten by the new
        // `scanTask = task` assignment), and both tasks would compete for the
        // main actor. The symptom was a UI hang on "Refresh" — the old scan's
        // synchronous `tree.aggregateSizes()` on 5M nodes held main long enough
        // that the new scan never got time to render its first frame.
        await drainInflightTasks()

        // Reset state
        phase = .red
        shallowTree = nil
        deepTree = nil
        smartScanResult = nil
        remainingDirectories = []
        lastConfiguration = configuration

        var finalStats: ScanStats?

        let task = Task { [weak self] in
            guard let self else { return }

            // ========================================
            // Phase 1: Shallow Scan (Red -> Yellow)
            // ========================================
            let shallowResult = await self.runPhase1(configuration: configuration)

            if Task.isCancelled { return }

            guard let (tree, phase1Stats) = shallowResult else { return }

            await MainActor.run {
                self.shallowTree = tree
                self.phase = .yellow
                self.onPhaseChange?(.yellow)
                self.onTreeUpdate?(tree)
            }

            // ========================================
            // Phase 2: Deep Scan (Yellow -> Green)
            // ========================================
            let deepResult = await self.runPhase2(
                shallowTree: tree,
                configuration: configuration,
                phase1Stats: phase1Stats
            )

            if Task.isCancelled { return }

            if let stats = deepResult {
                finalStats = stats
            }

            await MainActor.run {
                // Only transition to .green if smart scan did not already
                // transition to .smartGreen. When smart scan reaches its
                // coverage threshold, runPhase2 returns nil and sets the
                // phase to .smartGreen; we must not overwrite that.
                if self.phase != .smartGreen {
                    self.phase = .green
                    self.onPhaseChange?(.green)
                    if let deepTree = self.deepTree {
                        self.onTreeUpdate?(deepTree)
                    }
                    // Release shallow tree -- deep tree has all data now
                    self.shallowTree = nil
                }
            }
        }

        scanTask = task
        await task.value

        return finalStats
    }

    /// Cancels the scan at any phase. Discards both trees.
    ///
    /// Synchronous — only sets the cancellation flag and drops state. To wait
    /// for the cancelled task to actually exit (e.g. before starting a new
    /// scan), call [cancelAndWait] instead.
    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        rescanTask?.cancel()
        rescanTask = nil
        // Detach orchestrator-owned callbacks so a late detached-task hop
        // (insertBatch / aggregateSizes / onTreeUpdate) cannot fire against
        // the just-cleared `tree`/`phase` state and resurrect torn UI.
        onPhaseChange = nil
        onProgress = nil
        onTreeUpdate = nil
        onRestricted = nil
        shallowTree = nil
        deepTree = nil
        phase = .red
    }

    /// Cancels the scan and awaits the running task to finish exiting.
    ///
    /// Use this before starting a new scan from the same orchestrator instance
    /// to guarantee the old task no longer holds the main actor when the new
    /// one starts (otherwise both tasks race on shared state).
    func cancelAndWait() async {
        let scan = scanTask
        let rescan = rescanTask
        scan?.cancel()
        rescan?.cancel()
        scanTask = nil
        rescanTask = nil
        // Mirror cancel(): drop the orchestrator-owned callbacks BEFORE
        // awaiting the tasks. Otherwise a late detached hop (insertBatch
        // / aggregateSizes / onTreeUpdate) firing after cancelAndWait
        // returns can resurrect the tree in the UI while the caller has
        // already cleared state in preparation for a fresh scan.
        onPhaseChange = nil
        onProgress = nil
        onTreeUpdate = nil
        onRestricted = nil
        _ = await scan?.value
        _ = await rescan?.value
        shallowTree = nil
        deepTree = nil
        phase = .red
    }

    /// Drains in-flight scan + rescan tasks without resetting state.
    /// Used internally by [startScan] before resetting orchestrator state.
    private func drainInflightTasks() async {
        let scan = scanTask
        let rescan = rescanTask
        scan?.cancel()
        rescan?.cancel()
        scanTask = nil
        rescanTask = nil
        _ = await scan?.value
        _ = await rescan?.value
    }

    // MARK: - Deletion Handling

    /// Called after files are deleted to check if coverage dropped below rescan threshold.
    ///
    /// When the user deletes files from the tree during a `.smartGreen` phase, the
    /// scanned coverage decreases. If it drops below the configured
    /// ``SmartScanSettings/rescanTriggerThreshold``, an incremental rescan of the
    /// remaining (previously unscanned) directories is triggered automatically.
    ///
    /// - Parameters:
    ///   - deletedBytes: Total logical bytes of the deleted files.
    ///   - volume: URL of the volume (unused; configuration is stored internally).
    func handleDeletion(deletedBytes: UInt64, volume: URL) {
        guard let settings = smartScanSettings,
              let result = smartScanResult,
              phase == .smartGreen,
              let configuration = lastConfiguration else { return }

        let newScannedBytes = result.scannedBytes > deletedBytes
            ? result.scannedBytes - deletedBytes
            : 0
        let newCoverage = result.estimatedUsedSpace > 0
            ? Double(newScannedBytes) / Double(result.estimatedUsedSpace)
            : 0

        // Update the stored result to reflect the deletion
        smartScanResult = SmartScanResult(
            coveragePercent: newCoverage,
            scannedBytes: newScannedBytes,
            estimatedUsedSpace: result.estimatedUsedSpace,
            unscannedDirectoryCount: result.unscannedDirectoryCount
        )

        if newCoverage < settings.rescanTriggerThreshold {
            performIncrementalRescan(configuration: configuration)
        }
    }

    // MARK: - Phase 1: Shallow Scan

    /// Runs the shallow scan and builds the directory-only tree.
    ///
    /// - Parameter configuration: The scan configuration.
    /// - Returns: A tuple of the built `FileTree` and phase 1 stats, or `nil` if cancelled.
    private func runPhase1(
        configuration: ScanConfiguration
    ) async -> (FileTree, ScanStats)? {
        let tree = FileTree()
        let scanner = ShallowScanner()
        let stream = scanner.scan(configuration: configuration)

        var phase1Stats: ScanStats?

        for await event in stream {
            if Task.isCancelled { return nil }

            switch event {
            case .fileFound(let node):
                tree.insert(node)

            case .progress(let progress):
                await MainActor.run {
                    self.onProgress?(progress)
                }

            case .restricted:
                await MainActor.run {
                    self.onRestricted?()
                }

            case .completed(let stats):
                phase1Stats = stats

            case .error, .directoryEntered, .directoryCompleted, .directorySkipped:
                break
            }
        }

        if Task.isCancelled { return nil }

        // Aggregate entry counts so parent dirs reflect total subtree weight.
        // (No aggregateSizes needed -- all byte sizes are 0 in Phase 1.)
        tree.aggregateEntryCounts()
        tree.finalizeBuild()

        guard let stats = phase1Stats else { return nil }
        return (tree, stats)
    }

    // MARK: - Phase 2: Deep Scan

    /// Runs the deep scan, populating the deep tree incrementally.
    ///
    /// Directories are processed in priority order. When smart scan is enabled,
    /// ``SmartScanPrioritizer`` reorders directories (Tier 1 first, then Tier 2 by
    /// cached size). When the coverage threshold is reached, a virtual "Other" node
    /// is inserted and the phase transitions to `.smartGreen`.
    ///
    /// Tree updates are throttled to at most one every 2 seconds to avoid
    /// overwhelming the visualization layer.
    ///
    /// - Parameters:
    ///   - shallowTree: The directory-only tree from Phase 1.
    ///   - configuration: The base scan configuration.
    ///   - phase1Stats: Stats from the shallow scan (for timing).
    /// - Returns: Final ``ScanStats`` from the deep scan, or `nil` if cancelled
    ///   or if smart scan reached the threshold (results in ``smartScanResult``).
    private func runPhase2(
        shallowTree: FileTree,
        configuration: ScanConfiguration,
        phase1Stats: ScanStats
    ) async -> ScanStats? {
        // Determine directory order based on smart scan settings
        let directories: [(path: String, entryCount: UInt32)]
        let isSmartScan = smartScanSettings?.isEnabled == true
            && (smartScanSettings?.coverageThreshold ?? 1.0) < 1.0

        if isSmartScan, let settings = smartScanSettings {
            // Smart Scan: use prioritizer with cached sizes for optimal ordering
            let cachedDirSizes = scanCache?.loadDirectorySizes()
            directories = SmartScanPrioritizer.buildPrioritizedQueue(
                settings: settings,
                shallowTree: shallowTree,
                cachedDirSizes: cachedDirSizes
            )
        } else {
            // Full scan: directories sorted by entry count (heaviest first)
            let sortedDirs = shallowTree.allDirectoriesByEntryCount()
            directories = sortedDirs.map { dir in
                let path = shallowTree.fullPath(of: dir.index)
                return (path: path, entryCount: dir.entryCount)
            }
        }

        // Compute volume used space for smart scan coverage calculation
        let usedSpace: UInt64
        if isSmartScan {
            usedSpace = Self.computeVolumeUsedSpace(rootURL: configuration.rootPath)
        } else {
            usedSpace = 0
        }

        // Build the Tier 1 path set for smart scan
        let tier1PathsSet: Set<String>?
        if isSmartScan, let settings = smartScanSettings {
            tier1PathsSet = Set(ScanProfile.tier1Paths(for: settings.profile))
        } else {
            tier1PathsSet = nil
        }

        // Create the deep tree with a capacity hint based on shallow tree.
        // Typical volumes have ~10-20 files per directory; cap at 20M to avoid
        // over-allocating on volumes with many empty dirs.
        let estimatedNodes = min(shallowTree.nodeCount * 15, 20_000_000)
        let tree = FileTree(estimatedNodeCount: estimatedNodes)
        await MainActor.run {
            self.deepTree = tree
        }

        // Run the deep scanner
        let scanner = DeepScanner()
        let stream = scanner.scan(
            directories: directories,
            configuration: configuration,
            smartScanSettings: self.smartScanSettings,
            estimatedUsedSpace: usedSpace,
            smartScanTier1Paths: tier1PathsSet
        )

        var lastTreeUpdateTime = ContinuousClock.now
        // Throttle onProgress UI callbacks independently of tree updates.
        // With 16 workers each emitting ≤10 progress events/sec plus one per
        // directory completion (~90/sec), unthrottled onProgress fires ~250/sec,
        // causing excessive @Observable notifications and SwiftUI re-renders.
        var lastProgressUITime = ContinuousClock.now
        var deepStats: ScanStats?

        // Track directory sizes for cache (path -> logical size after scan)
        var directorySizeMap: [String: UInt64] = [:]

        // Track which directory index we're at for remaining directories calculation
        var lastCompletedDirIndex = -1

        // Batch buffer for insert — reduces lock acquisitions from once-per-file to once-per-batch.
        // 4096 nodes per batch balances lock overhead vs latency.
        let insertBatchSize = 4096
        var insertBuffer: [RawFileNode] = []
        insertBuffer.reserveCapacity(insertBatchSize)

        for await event in stream {
            if Task.isCancelled { return nil }

            switch event {
            case .filesBatch(let nodes):
                insertBuffer.append(contentsOf: nodes)
                if insertBuffer.count >= insertBatchSize {
                    let toInsert = insertBuffer
                    insertBuffer.removeAll(keepingCapacity: true)
                    // Offload heavy insert off MainActor — FileTree has internal
                    // locking, but inserting 4K nodes inline blocks the consumer
                    // loop and freezes the UI on large volumes.
                    await Task.detached(priority: .userInitiated) {
                        tree.insertBatch(toInsert)
                    }.value
                }

            case .directoryCompleted(let path, let dirIndex, _):
                // Flush pending nodes before processing directory completion
                if !insertBuffer.isEmpty {
                    let toInsert = insertBuffer
                    insertBuffer.removeAll(keepingCapacity: true)
                    await Task.detached(priority: .userInitiated) {
                        tree.insertBatch(toInsert)
                    }.value
                }
                lastCompletedDirIndex = dirIndex

                // Throttle tree update callbacks to max 1 per 2 seconds.
                // IMPORTANT: aggregateSizes() is O(N) and must NOT be called
                // after every directory — doing so blocks the consumer, causing
                // the AsyncStream buffer to overflow and drop fileFound events.
                // Instead, aggregate only before UI updates (throttled) and at
                // the very end.
                let now = ContinuousClock.now
                let elapsed = now - lastTreeUpdateTime
                if elapsed >= .seconds(Self.treeUpdateThrottleInterval) {
                    lastTreeUpdateTime = now
                    // Aggregate off MainActor — O(N) traversal of the entire tree
                    // would otherwise lock the UI on every throttle tick.
                    let aggregatedPathSize = await Task.detached(priority: .userInitiated) {
                        tree.aggregateSizes()
                        return tree.logicalSize(ofPath: path)
                    }.value
                    directorySizeMap[path] = aggregatedPathSize
                    self.onTreeUpdate?(tree)
                }

            case .progress(let progress):
                // Throttle UI updates to ≤10/sec. Without this, 16 workers × 10/sec
                // plus per-directory completion events produce ~250 onProgress calls/sec,
                // flooding the @Observable machinery and causing UI jank.
                let nowP = ContinuousClock.now
                if nowP - lastProgressUITime >= .milliseconds(500) {
                    lastProgressUITime = nowP
                    self.onProgress?(progress)
                }

            case .restricted:
                self.onRestricted?()

            case .error:
                break

            case .completed(let stats):
                deepStats = stats

            case .smartThresholdReached(let coverage, let scannedBytes):
                // Flush pending nodes before finalizing
                if !insertBuffer.isEmpty {
                    let toInsert = insertBuffer
                    insertBuffer.removeAll(keepingCapacity: true)
                    await Task.detached(priority: .userInitiated) {
                        tree.insertBatch(toInsert)
                    }.value
                }
                // Smart Scan threshold reached: finalize partial tree (off main).
                let otherSize = max(0, Int64(usedSpace) - Int64(scannedBytes))
                await Task.detached(priority: .userInitiated) {
                    tree.aggregateSizes()
                    tree.insertVirtualOtherNode(otherSize: UInt64(otherSize))
                    // Re-aggregate so root includes the virtual Other node
                    tree.aggregateSizes()
                }.value

                // Store remaining directories (everything after the last completed)
                let remainingStartIndex = lastCompletedDirIndex + 1
                let remaining: [(path: String, entryCount: UInt32)]
                if remainingStartIndex < directories.count {
                    remaining = Array(directories[remainingStartIndex...])
                } else {
                    remaining = []
                }

                await MainActor.run {
                    self.remainingDirectories = remaining
                    self.smartScanResult = SmartScanResult(
                        coveragePercent: coverage,
                        scannedBytes: scannedBytes,
                        estimatedUsedSpace: usedSpace,
                        unscannedDirectoryCount: remaining.count
                    )

                    // Do NOT call tree.finalizeBuild() -- keep pathIndex
                    // for incremental rescan insertions.

                    self.phase = .smartGreen
                    self.onPhaseChange?(.smartGreen)
                    self.onTreeUpdate?(tree)

                    // Release shallow tree -- deep tree is now the active tree
                    self.shallowTree = nil
                }

                // Save directory sizes to cache for future scan prioritization
                if !directorySizeMap.isEmpty {
                    try? scanCache?.saveDirectorySizes(directorySizeMap)
                }

                // Return nil: stats are on smartScanResult, not ScanStats
                return nil
            }
        }

        if Task.isCancelled { return nil }

        // Flush any remaining nodes in the insert buffer (off main).
        if !insertBuffer.isEmpty {
            let toInsert = insertBuffer
            insertBuffer.removeAll(keepingCapacity: true)
            await Task.detached(priority: .userInitiated) {
                tree.insertBatch(toInsert)
            }.value
        }

        // Full scan completed (no threshold reached) — finalize off main.
        await Task.detached(priority: .userInitiated) {
            tree.aggregateSizes()
            tree.diagnosticDump()
            tree.finalizeBuild()
        }.value

        // Save directory sizes to cache for future smart scan prioritization
        if !directorySizeMap.isEmpty {
            try? scanCache?.saveDirectorySizes(directorySizeMap)
        }

        return deepStats
    }

    // MARK: - Incremental Rescan

    /// Background rescan of remaining directories after coverage drops below threshold.
    ///
    /// Cancels any existing rescan task, then iterates over ``remainingDirectories``,
    /// inserting newly discovered nodes into the existing deep tree and shrinking the
    /// virtual "Other" node as real data replaces estimates.
    ///
    /// - Parameter configuration: The scan configuration to use for the rescan.
    private func performIncrementalRescan(configuration: ScanConfiguration) {
        rescanTask?.cancel()

        let directories = self.remainingDirectories
        let smartSettings = self.smartScanSettings
        let estimatedUsed = self.smartScanResult?.estimatedUsedSpace ?? 0

        // Task.detached: rescanTask used to inherit MainActor from this
        // @MainActor method, so the `for await event in stream` loop ran on
        // the main thread between detached heavy-op hops. Detaching pushes
        // the whole consumer loop off main; MainActor-only writes go through
        // explicit `MainActor.run { ... }` hops.
        rescanTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let tree: FileTree? = await MainActor.run { self.deepTree }
            guard let tree else { return }

            let scanner = DeepScanner()
            let stream = scanner.scan(
                directories: directories,
                configuration: configuration,
                smartScanSettings: smartSettings,
                estimatedUsedSpace: estimatedUsed,
                smartScanTier1Paths: nil
            )

            var rescanBuffer: [RawFileNode] = []
            rescanBuffer.reserveCapacity(512)

            for await event in stream {
                if Task.isCancelled { break }

                switch event {
                case .filesBatch(let nodes):
                    rescanBuffer.append(contentsOf: nodes)
                    if rescanBuffer.count >= 512 {
                        let toInsert = rescanBuffer
                        rescanBuffer.removeAll(keepingCapacity: true)
                        // Heavy insert OFF MainActor — rescanTask inherits
                        // @MainActor from the @MainActor class; without this
                        // hop, every 512 nodes blocks the UI on insertBatch.
                        await Task.detached(priority: .userInitiated) {
                            tree.insertBatch(toInsert)
                        }.value
                    }

                case .directoryCompleted:
                    if !rescanBuffer.isEmpty {
                        let toInsert = rescanBuffer
                        rescanBuffer.removeAll(keepingCapacity: true)
                        await Task.detached(priority: .userInitiated) {
                            tree.insertBatch(toInsert)
                        }.value
                    }
                    // Approximate "Other" sizing without the O(N) aggregate.
                    let used = estimatedUsed
                    let scanned = await Task.detached(priority: .userInitiated) {
                        tree.logicalSize(of: tree.rootIndex)
                    }.value
                    let newOther = max(0, Int64(used) - Int64(scanned))
                    await Task.detached(priority: .userInitiated) {
                        tree.updateVirtualOtherSize(UInt64(newOther))
                    }.value

                    // The detached rescan task can't touch @MainActor state
                    // directly — hop to main for the callback dispatch.
                    await MainActor.run { self.onTreeUpdate?(tree) }

                case .smartThresholdReached(let coverage, let scannedBytes):
                    await MainActor.run {
                        self.smartScanResult = SmartScanResult(
                            coveragePercent: coverage,
                            scannedBytes: scannedBytes,
                            estimatedUsedSpace: estimatedUsed,
                            unscannedDirectoryCount: 0
                        )
                    }

                default:
                    break
                }
            }

            // Final flush + aggregate off MainActor.
            if !rescanBuffer.isEmpty {
                let toInsert = rescanBuffer
                rescanBuffer.removeAll(keepingCapacity: true)
                await Task.detached(priority: .userInitiated) {
                    tree.insertBatch(toInsert)
                }.value
            }
            let finalOther = await Task.detached(priority: .userInitiated) { () -> UInt64 in
                tree.aggregateSizes()
                let finalScanned = tree.logicalSize(of: tree.rootIndex)
                let other = max(0, Int64(estimatedUsed) - Int64(finalScanned))
                tree.updateVirtualOtherSize(UInt64(other))
                return UInt64(other)
            }.value
            _ = finalOther
            await MainActor.run { self.onTreeUpdate?(tree) }
        }
    }

    // MARK: - Incremental Cache Rescan

    /// Performs an incremental rescan of only the specified dirty directories.
    ///
    /// Uses the cached tree as the base and rescans only directories that changed
    /// since the cache was written. For each dirty directory, a ``BulkDiskScanner``
    /// scan is performed, the results are patched into the tree via
    /// ``FileTree/applyWALPatch(dirPath:walNodes:walStringPoolData:)``, and a WAL
    /// entry is written for crash-resilient persistence.
    ///
    /// After all dirty directories are rescanned, sizes are re-aggregated once and
    /// ``onTreeUpdate`` is fired to refresh the UI.
    ///
    /// ## Prerequisites
    /// - `cachedTree` must have ``FileTree/prepareForPatching()`` called prior to
    ///   this method so that the internal `pathIndex` is populated.
    /// - `cache` must be a valid ``ScanCache`` with a functional WAL.
    ///
    /// ## Thread Safety
    /// The method is `@MainActor`-isolated (inheriting from the class). The heavy
    /// scanning work runs on detached tasks via ``BulkDiskScanner``, and tree
    /// mutations use the tree's internal `os_unfair_lock`.
    ///
    /// - Parameters:
    ///   - cachedTree: The ``FileTree`` loaded from cache (must have
    ///     ``FileTree/prepareForPatching()`` called).
    ///   - dirtyPaths: List of directory paths that need rescanning (from ``CacheValidator``).
    ///   - configuration: Scan configuration for the rescan.
    ///   - cache: ``ScanCache`` instance for WAL writes.
    /// - Returns: Summary of changes (bytes added/removed, directories rescanned).
    func startIncrementalRescan(
        cachedTree: FileTree,
        dirtyPaths: [String],
        configuration: ScanConfiguration,
        cache: ScanCache
    ) async -> IncrementalRescanResult {
        let startTime = ContinuousClock.now

        // Serialize against the previous rescan: cancel the handle AND
        // await its exit before mutating the same `cachedTree`. Without the
        // await, the new detached patcher's `applyWALPatch` + `aggregateSizes`
        // interleaved with the cancelled-but-still-finishing previous one,
        // producing inconsistent intermediate sums.
        let previousRescan = rescanTask
        previousRescan?.cancel()
        _ = await previousRescan?.value

        // Capture root size before patching to measure change
        let rootSizeBefore = Int64(cachedTree.logicalSize(of: cachedTree.rootIndex))

        // Set the deep tree to the cached tree so activeTree returns it.
        // Use `.yellow` (deep-scan-in-progress) for the duration of the
        // patch loop — leaving phase at `.red` made `activeTree` look like
        // a cold start and SwiftUI hid the tree until phase finally moved
        // to `.green` at the end.
        self.deepTree = cachedTree
        self.phase = .yellow

        // Heavy loop OFF MainActor — orchestrator is @MainActor so without this
        // detach the BulkDiskScanner stream consumer, applyWALPatch, WAL append,
        // and final aggregateSizes all run on main and freeze the UI for the
        // entire duration of the rescan.
        //
        // Track the detached patch task via `rescanTask` so `cancel()` /
        // `cancelAndWait()` can actually stop it. The prior handle has
        // already been awaited above, so no late mutation collides here.
        let patchTask: Task<Int, Never> = Task.detached(priority: .userInitiated) {
            var count = 0
            for dirPath in dirtyPaths {
                if Task.isCancelled { break }

                let scopedConfig = ScanConfiguration(
                    rootPath: URL(filePath: dirPath),
                    volumeId: configuration.volumeId,
                    followSymlinks: configuration.followSymlinks,
                    crossMountPoints: configuration.crossMountPoints,
                    includeHidden: configuration.includeHidden,
                    batchSize: configuration.batchSize,
                    throttleInterval: configuration.throttleInterval,
                    exclusionRules: configuration.exclusionRules
                )

                let scanner = BulkDiskScanner()
                let stream = scanner.scan(configuration: scopedConfig)

                var rawNodes = [RawFileNode]()

                for await event in stream {
                    if Task.isCancelled { break }

                    switch event {
                    case .fileFound(let node):
                        rawNodes.append(node)
                    default:
                        break
                    }
                }

                if Task.isCancelled { break }

                let childNodes = rawNodes.filter { $0.path != dirPath }
                let (walNodes, walStringPoolData) = Self.buildWALEntry(from: childNodes)

                cachedTree.applyWALPatch(
                    dirPath: dirPath,
                    walNodes: walNodes,
                    walStringPoolData: walStringPoolData
                )

                let dirPathHash = ScanCacheWAL.fnv1aHash(dirPath)
                try? cache.wal.append(
                    dirPathHash: dirPathHash,
                    nodes: walNodes,
                    stringPoolData: walStringPoolData
                )

                count += 1
            }

            // Re-aggregate sizes across the entire tree once after all patches.
            cachedTree.aggregateSizes()
            return count
        }
        // Hold the patch task as a `Task<Void, Never>` via a wrapper so it
        // matches `rescanTask`'s type and can be awaited from cancelAndWait.
        // The wrapper actively cancels the inner detached task on its own
        // cancellation — `Task<Void, Never> { ... }` does not propagate
        // cancellation to a detached child task, so `voidWrap.cancel()`
        // would otherwise leave the WAL writes running after cancelAndWait.
        let voidWrap = Task<Void, Never> {
            await withTaskCancellationHandler {
                _ = await patchTask.value
            } onCancel: {
                patchTask.cancel()
            }
        }
        rescanTask = voidWrap
        let directoriesRescanned = await patchTask.value
        _ = await voidWrap.value

        // Now that the patch loop finished (or was cancelled), promote phase.
        if !Task.isCancelled {
            self.phase = .green
        }

        let rootSizeAfter = Int64(cachedTree.logicalSize(of: cachedTree.rootIndex))
        let bytesChanged = rootSizeAfter - rootSizeBefore

        // Fire a single UI update on MainActor — but only if the
        // surrounding task was not cancelled. Without this guard, an
        // incremental rescan whose stream finished just as the user pressed
        // Cancel would resurrect the tree in the UI after `cancel()` had
        // already cleared it.
        if !Task.isCancelled {
            self.onTreeUpdate?(cachedTree)
        }

        let elapsed = ContinuousClock.now - startTime
        let durationSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        return IncrementalRescanResult(
            directoriesRescanned: directoriesRescanned,
            bytesChanged: bytesChanged,
            duration: durationSeconds
        )
    }

    /// Converts an array of ``RawFileNode``s into WAL-compatible format.
    ///
    /// Creates a temporary ``StringPool`` and builds ``FileNode`` structs
    /// with name offsets relative to that pool. The resulting nodes and pool
    /// data can be passed to ``FileTree/applyWALPatch(dirPath:walNodes:walStringPoolData:)``
    /// and ``ScanCacheWAL/append(dirPathHash:nodes:stringPoolData:)``.
    ///
    /// - Parameter rawNodes: The raw file nodes from the scanner.
    /// - Returns: A tuple of `(walNodes, stringPoolData)` suitable for WAL operations.
    nonisolated private static func buildWALEntry(
        from rawNodes: [RawFileNode]
    ) -> (nodes: [FileNode], stringPoolData: Data) {
        var walPool = StringPool(initialCapacity: rawNodes.count * 20)
        var walNodes = [FileNode]()
        walNodes.reserveCapacity(rawNodes.count)

        for raw in rawNodes {
            let (nameOffset, nameLength) = walPool.append(raw.name)

            let node = FileNode(
                nameOffset: nameOffset,
                nameLength: nameLength,
                parentIndex: 0, // Meaningless in WAL context; resolved during applyWALPatch
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
            walNodes.append(node)
        }

        return (walNodes, walPool.serializedData)
    }

    // MARK: - Helpers

    /// Computes the used space on the volume containing the given URL.
    ///
    /// Used space is calculated as `totalCapacity - availableCapacity`.
    /// Returns 0 if the resource values cannot be read.
    ///
    /// - Parameter rootURL: A URL on the target volume.
    /// - Returns: Estimated used bytes on the volume.
    private static func computeVolumeUsedSpace(rootURL: URL) -> UInt64 {
        do {
            let resourceValues = try rootURL.resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
            )
            let total = resourceValues.volumeTotalCapacity ?? 0
            let available = resourceValues.volumeAvailableCapacity ?? 0
            let used = max(0, total - available)
            return UInt64(used)
        } catch {
            return 0
        }
    }
}
