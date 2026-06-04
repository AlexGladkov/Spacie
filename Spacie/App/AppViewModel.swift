import SwiftUI
import CoreServices

// MARK: - CacheStatus

/// Describes the current state of the incremental scan cache relative to the UI.
///
/// Used by ``AppViewModel`` to communicate cache loading and validation progress
/// to the ``InfoBarView`` for displaying status banners.
enum CacheStatus: Equatable, Sendable {
    /// No cache exists for this volume (or has not been checked yet).
    case none
    /// Cache was loaded and is being validated in the background.
    case loadedChecking(lastScanDate: Date)
    /// Background validation found dirty directories that were rescanned.
    case changesFound(addedBytes: Int64, dirCount: Int)
    /// Cache is fully up to date with the filesystem.
    case upToDate
    /// Cache was corrupted and a full scan is starting.
    case corrupted
    /// The cached volume is no longer mounted / accessible.
    case volumeNotMounted
    /// A previously interrupted scan is being resumed from cache.
    case resumingScan
}

// MARK: - ActivePanel

/// Identifies which feature panel is currently displayed in the main content area.
enum ActivePanel: String, Sendable, CaseIterable, Identifiable {
    case visualization
    case largeFiles
    case duplicates
    case smartCategories
    case oldFiles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visualization: "Visualization"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .smartCategories: "Smart Clean"
        case .oldFiles: "Old Files"
        }
    }

    var systemImage: String {
        switch self {
        case .visualization: "circle.circle"
        case .largeFiles: "doc.fill"
        case .duplicates: "doc.on.doc.fill"
        case .smartCategories: "wand.and.stars"
        case .oldFiles: "clock.fill"
        }
    }
}

// MARK: - AppViewModel

/// Primary view model for a single tab / scan session.
///
/// Orchestrates the scan lifecycle, manages navigation state, and holds
/// references to the active file tree and visualization parameters.
@MainActor
@Observable
final class AppViewModel {

    // MARK: - State

    /// The volume currently selected for scanning.
    var volume: VolumeInfo?

    /// Current state of the scan pipeline.
    var scanState: ScanState = .idle

    /// Current phase of the two-phase scan.
    var scanPhase: ScanPhase = .red

    /// The resulting file tree after a successful scan.
    var tree: FileTree?

    /// Monotonically increasing counter bumped on every tree content mutation.
    /// Views that depend on tree data should include this in their identity
    /// or task keys so SwiftUI re-evaluates when the tree's internal state changes.
    var treeVersion: Int = 0

    /// Whether sizes display logical or physical values.
    var sizeMode: SizeMode {
        didSet { UserDefaults.standard.set(sizeMode.rawValue, forKey: "defaultSizeMode") }
    }

    /// Which feature panel is currently active in the main content area.
    var activePanel: ActivePanel = .visualization

    /// User-entered search query for filtering files.
    var searchQuery: String = ""

    /// Visualization navigation state shared with visualization views.
    var vizState: VisualizationState?

    /// View model for the Large Files panel.
    let largeFilesVM = LargeFilesViewModel()

    /// View model for the Duplicate Finder panel.
    let duplicateFinderVM = DuplicateFinderViewModel()

    /// Whether the FDA banner should be displayed.
    var showFDABanner: Bool = false

    /// Whether the "go to folder" sheet is presented.
    var showGoToFolder: Bool = false

    /// Path entered by the user in the Go to Folder dialog.
    var goToFolderPath: String = ""

    /// Wall-clock timestamp when the current scan started.
    /// Used by the info bar for a live-updating elapsed timer.
    var scanStartDate: Date?

    /// Timestamp of the last completed scan.
    var lastScanDate: Date?

    /// Whether FSEvents have detected changes since the last scan.
    var dataIsStale: Bool = false

    // MARK: - Smart Scan Settings

    /// Whether Smart Scan is enabled.
    var smartScanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smartScanEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smartScanEnabled") }
    }

    /// The active scan profile for Smart Scan.
    var smartScanProfile: ScanProfileType {
        get {
            let raw = UserDefaults.standard.string(forKey: "smartScanProfile") ?? ScanProfileType.default.rawValue
            return ScanProfileType(rawValue: raw) ?? .default
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "smartScanProfile") }
    }

    /// Coverage threshold for Smart Scan (0.0 - 1.0).
    var smartScanCoverageThreshold: Double {
        get {
            let value = UserDefaults.standard.double(forKey: "smartScanCoverageThreshold")
            return value > 0 ? value : 0.95
        }
        set { UserDefaults.standard.set(newValue, forKey: "smartScanCoverageThreshold") }
    }

    /// Builds a ``SmartScanSettings`` from the current user defaults, or `nil` if disabled.
    var smartScanSettings: SmartScanSettings? {
        guard smartScanEnabled else { return nil }
        return SmartScanSettings(
            isEnabled: true,
            profile: smartScanProfile,
            coverageThreshold: smartScanCoverageThreshold
        )
    }

    /// Current cache status, displayed in the info bar as a subtle banner.
    var cacheStatus: CacheStatus = .none

    // MARK: - Private

    private let orchestrator = ScanOrchestrator()
    private var scanTask: Task<Void, Never>?

    /// Persistent scan cache instance for the current volume.
    /// Created lazily when a scan starts or cache is loaded.
    private(set) var scanCache: ScanCache?

    /// Whether a cache file exists on disk for the current volume.
    ///
    /// Stored rather than computed so it is safe to read from SwiftUI body closures
    /// without triggering filesystem I/O (which caused a performance regression where
    /// every progress-update re-render performed `createDirectory` + `stat`).
    private(set) var cacheExistsForVolume: Bool = false

    /// Background task for cache validation and auto-dismiss.
    private var cacheValidationTask: Task<Void, Never>?

    /// Prevents App Nap from throttling the scan while in background.
    private var scanActivity: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        let savedSize = UserDefaults.standard.string(forKey: "defaultSizeMode") ?? SizeMode.logical.rawValue
        self.sizeMode = SizeMode(rawValue: savedSize) ?? .logical

        // Register defaults for Smart Scan settings.
        UserDefaults.standard.register(defaults: [
            "smartScanEnabled": true,
            "smartScanCoverageThreshold": 0.95,
        ])
    }

    // MARK: - Scan

    /// Initiates a scan of the selected volume via ``ScanOrchestrator``.
    ///
    /// If a valid cache exists for the volume, the cached tree is loaded and displayed
    /// instantly while background validation checks for filesystem changes. Only dirty
    /// directories are rescanned incrementally. If no cache exists or the cache is
    /// corrupted, a full two-phase scan is performed.
    ///
    /// **Full scan path:**
    /// - **Phase 1 (Red)**: Fast directory-only scan producing a shallow tree with
    ///   entry counts but no file sizes.
    /// - **Phase 2 (Yellow -> Green)**: Deep per-folder scan running in the background
    ///   with throttled UI updates.
    ///
    /// **Cached path:**
    /// - Load blob + WAL, display instantly, validate in background, incremental rescan
    ///   of dirty directories only.
    func startScan() async {
        guard let volume else { return }

        cancelScan()

        // Prevent App Nap from throttling the scan when the window is not visible.
        scanActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Disk scanning in progress"
        )

        let configuration = ScanConfiguration(
            rootPath: volume.mountPoint,
            volumeId: volume.id,
            // crossMountPoints: false — APFS firmlinks share the same st_dev as "/"
            // so they are traversed normally; simulator APFS volumes (disk5s1, disk7s1…)
            // have different st_dev and are blocked by the cross-device check.
            // This makes the /Library/Developer/CoreSimulator exclusion unnecessary.
            crossMountPoints: false
        )

        // Try the incremental cache path first
        let cache = ScanCache(volumeId: volume.id)
        self.scanCache = cache
        orchestrator.scanCache = cache
        self.cacheExistsForVolume = cache.cacheExists

        if cache.cacheExists {
            let loaded = await attemptCacheLoad(cache: cache, configuration: configuration)
            if loaded {
                endScanActivity()
                return
            }
        }

        // No cache or cache load failed: run full scan
        cacheStatus = .none
        await startFullScan(volume: volume, configuration: configuration)
    }

    /// Attempts to load the scan from cache and handle crash recovery.
    ///
    /// Returns `true` if the cache was successfully loaded and the incremental
    /// path is being used. Returns `false` if a full scan should be performed instead.
    ///
    /// ## Crash Recovery (Step 11)
    /// - `scanComplete == true`: Normal incremental validation path.
    /// - `scanComplete == false, lastPhase == 1`: Phase 1 was interrupted.
    ///   Restart Phase 1 from scratch (fast, 5-15 sec).
    /// - `scanComplete == false, lastPhase == 2`: Phase 2 was interrupted.
    ///   Show the cached tree and resume scanning remaining directories.
    private func attemptCacheLoad(
        cache: ScanCache,
        configuration: ScanConfiguration
    ) async -> Bool {
        // Verify the volume is still mounted / accessible before attempting
        // to load and validate the cache. Without this check, CacheValidator
        // would lstat() every cached directory, all would fail, and we'd
        // trigger a massive rescan destined to fail.
        let rootPath = configuration.rootPath.path(percentEncoded: false)
        guard FileManager.default.isReadableFile(atPath: rootPath) else {
            cacheStatus = .volumeNotMounted
            return true // Return true to prevent falling through to full scan
        }

        // Deserialize the cache blob on a background thread to avoid blocking
        // the main thread for large caches (5M nodes at ~72B = ~360 MB).
        let loadTask = Task.detached(priority: .userInitiated) { cache.load() }
        guard let cachedTree = await loadTask.value else {
            // Cache exists but is corrupted or unreadable
            cacheStatus = .corrupted
            cache.invalidate()
            // Auto-dismiss corrupted banner after 3 seconds
            scheduleCacheStatusDismiss(after: 3.0)
            return false
        }

        // --- Crash Recovery Logic (Step 11) ---

        if !cache.scanComplete {
            return await handleIncompleteCache(
                cache: cache,
                cachedTree: cachedTree,
                configuration: configuration
            )
        }

        // --- Normal Incremental Path (Step 9) ---

        // Apply any WAL entries on top of the base blob
        cachedTree.prepareForPatching()
        applyWALEntries(cache: cache, tree: cachedTree)

        // Display the cached tree immediately
        self.tree = cachedTree
        self.treeVersion += 1
        self.scanPhase = .green
        self.scanState = .completed(ScanStats(
            totalFiles: UInt64(cachedTree.nodeCount),
            totalDirectories: 0,
            totalLogicalSize: cachedTree.logicalSize(of: cachedTree.rootIndex),
            totalPhysicalSize: cachedTree.physicalSize(of: cachedTree.rootIndex),
            restrictedDirectories: 0,
            skippedDirectories: 0,
            scanDuration: 0,
            volumeId: configuration.volumeId
        ))

        let vs = VisualizationState(
            rootIndex: cachedTree.rootIndex,
            sizeMode: sizeMode
        )
        self.vizState = vs
        self.lastScanDate = cache.lastScanDate
        self.dataIsStale = false
        self.cacheStatus = .loadedChecking(lastScanDate: cache.lastScanDate ?? Date())

        // Start background validation
        cacheValidationTask?.cancel()
        cacheValidationTask = Task { [weak self] in
            guard let self else { return }

            let validator = CacheValidator()
            let rootPath = configuration.rootPath.path(percentEncoded: false)

            let result = await validator.validate(
                tree: cachedTree,
                rootPath: rootPath
            )

            if Task.isCancelled { return }

            if result.dirtyDirectories.isEmpty {
                self.cacheStatus = .upToDate
                self.scheduleCacheStatusDismiss(after: 3.0)
            } else {
                // Incremental rescan of only dirty directories
                let rescanResult = await self.orchestrator.startIncrementalRescan(
                    cachedTree: cachedTree,
                    dirtyPaths: result.dirtyDirectories,
                    configuration: configuration,
                    cache: cache
                )

                if Task.isCancelled { return }

                self.tree = cachedTree
                self.treeVersion += 1
                self.cacheStatus = .changesFound(
                    addedBytes: rescanResult.bytesChanged,
                    dirCount: rescanResult.directoriesRescanned
                )

                // Save updated tree to cache (Step 10: after incremental rescan)
                let eventId = FSEventsMonitor.currentSystemEventId()
                try? cache.save(
                    tree: cachedTree,
                    scanComplete: true,
                    lastPhase: 2,
                    lastEventId: eventId
                )

                // Check WAL compaction
                if cache.shouldCompact() {
                    Task.detached(priority: .utility) {
                        try? cache.compactWAL(tree: cachedTree, lastEventId: eventId)
                    }
                }

                self.scheduleCacheStatusDismiss(after: 5.0)
            }

            // Start FSEvents monitoring for future changes
            cache.startMonitoring(path: configuration.rootPath.path(percentEncoded: false))
        }

        return true
    }

    /// Handles cache load when the previous scan was interrupted (crash recovery).
    ///
    /// - `lastPhase == 1`: Phase 1 was interrupted. Discard cache, restart from scratch.
    /// - `lastPhase == 2`: Phase 2 was interrupted. Show cached Phase 1 tree and resume.
    private func handleIncompleteCache(
        cache: ScanCache,
        cachedTree: FileTree,
        configuration: ScanConfiguration
    ) async -> Bool {
        if cache.lastPhase <= 1 {
            // Phase 1 was interrupted: restart from scratch (fast, 5-15 sec)
            cache.invalidate()
            return false
        }

        // Phase 2 was interrupted: show cached tree and resume scanning
        cacheStatus = .resumingScan

        cachedTree.prepareForPatching()
        applyWALEntries(cache: cache, tree: cachedTree)

        // Display the partial tree immediately
        self.tree = cachedTree
        self.scanPhase = .yellow
        let vs = VisualizationState(
            rootIndex: cachedTree.rootIndex,
            sizeMode: sizeMode
        )
        vs.useEntryCount = false // Phase 1 data has no sizes, but Phase 2 partial does
        self.vizState = vs
        self.lastScanDate = cache.lastScanDate

        // Determine what still needs scanning:
        // Use FSEvents sinceWhen to detect changes during the crash window,
        // then rescan unscanned dirs + any changed dirs.
        let eventId = cache.lastEventId

        cacheValidationTask?.cancel()
        cacheValidationTask = Task { [weak self] in
            guard let self else { return }

            // Validate all directories to find what changed
            let validator = CacheValidator()
            let rootPath = configuration.rootPath.path(percentEncoded: false)
            let result = await validator.validate(tree: cachedTree, rootPath: rootPath)

            if Task.isCancelled { return }

            // Rescan all dirty dirs (includes both unscanned and changed)
            let dirtyPaths = result.dirtyDirectories
            if !dirtyPaths.isEmpty {
                let rescanResult = await self.orchestrator.startIncrementalRescan(
                    cachedTree: cachedTree,
                    dirtyPaths: dirtyPaths,
                    configuration: configuration,
                    cache: cache
                )

                if Task.isCancelled { return }
                self.tree = cachedTree
            }

            // Mark as complete now
            self.scanPhase = .green
            self.cacheStatus = .none
            self.lastScanDate = Date()

            // Save the now-complete tree
            let newEventId = FSEventsMonitor.currentSystemEventId()
            try? cache.save(
                tree: cachedTree,
                scanComplete: true,
                lastPhase: 2,
                lastEventId: newEventId
            )

            cache.startMonitoring(path: rootPath)
        }

        return true
    }

    /// Applies WAL entries to a cached tree.
    ///
    /// Reads all valid WAL entries and patches them into the tree.
    /// The tree must have ``FileTree/prepareForPatching()`` called beforehand.
    private func applyWALEntries(cache: ScanCache, tree: FileTree) {
        guard cache.wal.isValid(baseFormatVersion: ScanCache.currentFormatVersion) else {
            cache.wal.deleteWAL()
            return
        }

        guard let entries = try? cache.wal.readAll(), !entries.isEmpty else {
            return
        }

        for entry in entries {
            // WAL entries store dirPathHash but not the resolved path.
            // We need to find the matching path by hash from the tree's pathIndex.
            // Since applyWALPatch requires the dirPath string, we must find it.
            // The tree's prepareForPatching rebuilt pathIndex, so we can search.
            // For now, skip WAL application if we can't resolve the path.
            // This is acceptable because the subsequent validation + incremental
            // rescan will catch any stale directories anyway.
            tree.applyWALPatch(
                dirPath: entry.dirPath,
                walNodes: entry.nodes,
                walStringPoolData: entry.stringPoolData
            )
        }

        tree.aggregateSizes()
    }

    /// Runs the standard two-phase full scan with cache writing at lifecycle points.
    private func startFullScan(volume: VolumeInfo, configuration: ScanConfiguration) async {
        scanPhase = .red
        scanStartDate = Date()
        scanState = .scanning(ScanProgress(
            filesScanned: 0,
            directoriesScanned: 0,
            skippedDirectories: 0,
            totalLogicalSizeScanned: 0,
            totalPhysicalSizeScanned: 0,
            currentPath: volume.mountPoint.path,
            elapsedTime: 0,
            estimatedTotalFiles: nil,
            phase: .red
        ))

        orchestrator.onPhaseChange = { [weak self] phase in
            guard let self else { return }
            self.scanPhase = phase
            if phase == .yellow {
                // Phase 1 complete -- switch to results screen with approximate data.
                if let tree = self.orchestrator.activeTree {
                    self.tree = tree
                    let rootIndex = tree.rootIndex
                    let vs = VisualizationState(rootIndex: rootIndex, sizeMode: self.sizeMode)
                    vs.useEntryCount = true
                    self.vizState = vs

                    // Step 10: Save cache after Phase 1 completion
                    if let cache = self.scanCache {
                        let eventId = FSEventsMonitor.currentSystemEventId()
                        try? cache.save(
                            tree: tree,
                            scanComplete: false,
                            lastPhase: 1,
                            lastEventId: eventId
                        )
                    }
                }
            } else if phase == .smartGreen {
                // Smart Scan threshold reached -- show accurate data (same as green).
                self.vizState?.useEntryCount = false
            } else if phase == .green {
                self.vizState?.useEntryCount = false
            }
        }

        orchestrator.onProgress = { [weak self] progress in
            // Animate the scanState change so numeric labels in InfoBarView smoothly
            // count up via .contentTransition(.numericText()). Duration is slightly
            // shorter than the throttle interval (500ms) so each update arrives just
            // as the previous animation finishes, creating a seamless counting effect.
            withAnimation(.linear(duration: 0.45)) {
                self?.scanState = .scanning(progress)
            }
        }

        orchestrator.onTreeUpdate = { [weak self] tree in
            guard let self else { return }
            self.tree = tree
            self.treeVersion += 1
            // During Phase 2 (yellow), switch from entry counts to actual sizes
            // since the deep tree has real size data but no entry counts.
            if self.scanPhase == .yellow, let vs = self.vizState, vs.useEntryCount {
                vs.useEntryCount = false
                // Reset navigation to root since deep tree indices differ from shallow tree
                vs.navigateToRoot()
            }
        }

        orchestrator.onRestricted = { [weak self] in
            self?.showFDABanner = true
        }

        scanTask = Task { [weak self] in
            guard let self else { return }
            if let stats = await self.orchestrator.startScan(configuration: configuration) {
                self.scanState = .completed(stats)
                self.scanStartDate = nil
                self.lastScanDate = Date()
                self.dataIsStale = false
                self.scanPhase = .green
                // Final tree swap to the fully accurate deep tree.
                if let deepTree = self.orchestrator.deepTree {
                    self.tree = deepTree
                    self.treeVersion += 1

                    // Step 10: Save cache after Phase 2 completion
                    if let cache = self.scanCache {
                        let eventId = FSEventsMonitor.currentSystemEventId()
                        try? cache.save(
                            tree: deepTree,
                            scanComplete: true,
                            lastPhase: 2,
                            lastEventId: eventId
                        )
                        // Delete WAL since we have a fresh complete blob
                        cache.wal.deleteWAL()
                        // Start FSEvents monitoring
                        cache.startMonitoring(
                            path: configuration.rootPath.path(percentEncoded: false)
                        )
                    }
                }
            } else if Task.isCancelled {
                self.scanState = .cancelled
            }
            self.endScanActivity()
        }
    }

    /// Cancels the currently running scan, if any.
    func cancelScan() {
        orchestrator.cancel()
        scanTask?.cancel()
        scanTask = nil
        cacheValidationTask?.cancel()
        cacheValidationTask = nil
        endScanActivity()
        scanStartDate = nil
        if scanState.isScanning {
            scanState = .cancelled
            scanPhase = .red
        }
    }

    /// Ends the App Nap prevention activity token.
    private func endScanActivity() {
        if let activity = scanActivity {
            ProcessInfo.processInfo.endActivity(activity)
            scanActivity = nil
        }
    }

    /// Called after a node has been successfully moved to Trash.
    ///
    /// Removes the node from the in-memory tree, re-aggregates sizes so parent
    /// directories reflect the deletion, and bumps `treeVersion` to trigger a
    /// UI refresh. Also notifies the orchestrator for Smart Scan coverage tracking.
    func handleNodeTrashed(index: UInt32) {
        guard let tree else { return }

        let deletedBytes = tree.removeNode(at: index)
        tree.aggregateSizes()
        treeVersion += 1

        // Notify orchestrator (Smart Scan rescan trigger)
        if let volume, deletedBytes > 0 {
            orchestrator.handleDeletion(deletedBytes: deletedBytes, volume: volume.mountPoint)
        }

        // Mark data as potentially stale for FSEvents-based future rescans
        dataIsStale = false
    }

    /// Resets to idle state without starting a new scan.
    /// Called after clearing the cache so the UI returns to the home screen.
    func resetToIdle() {
        cancelScan()
        tree = nil
        vizState = nil
        scanState = .idle
        scanPhase = .red
        dataIsStale = false
        cacheStatus = .none
        scanCache = nil
        cacheExistsForVolume = false
    }

    /// Discards the current tree and rescans the same volume from scratch.
    ///
    /// Awaits a full drain of any in-flight scan/rescan/validation tasks before
    /// starting the new scan. Without this, clicking "Refresh" while the
    /// previous scan was still aggregating sizes (synchronous O(N) on main)
    /// produced a UI hang — both old and new scans competed for the main
    /// actor and corrupted each other's tree state.
    func rescan() async {
        // 1. Cancel and wait for everything in flight to actually exit.
        cancelScan()
        if let task = scanTask { _ = await task.value }
        if let task = cacheValidationTask { _ = await task.value }
        await orchestrator.cancelAndWait()

        // 2. Now safe to clear references and start fresh.
        tree = nil
        vizState = nil
        scanState = .idle
        scanPhase = .red
        dataIsStale = false
        cacheStatus = .none
        scanCache?.invalidate()
        scanCache = nil

        await startScan()
    }

    /// Saves the current tree state to the scan cache.
    ///
    /// Called on app termination (`NSApplication.willTerminateNotification`) to persist
    /// the latest tree state and FSEvents event ID. This ensures that on the next launch,
    /// the cache reflects the most recent data and can detect changes that occurred
    /// between the save and the app's termination.
    func saveCurrentStateToCache() {
        guard let cache = scanCache, let tree = tree else { return }

        let eventId = FSEventsMonitor.currentSystemEventId()
        let isComplete = scanPhase == .green || scanPhase == .smartGreen
        let phase: UInt8 = scanPhase == .red ? 0 : (scanPhase == .yellow ? 1 : 2)

        try? cache.save(
            tree: tree,
            scanComplete: isComplete,
            lastPhase: phase,
            lastEventId: eventId
        )
        cacheExistsForVolume = true
    }

    /// Schedules auto-dismissal of the cache status banner after a delay.
    ///
    /// - Parameter seconds: Delay in seconds before setting ``cacheStatus`` to `.none`.
    private func scheduleCacheStatusDismiss(after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            // Only dismiss if still showing a dismissable status
            switch self.cacheStatus {
            case .upToDate, .changesFound, .corrupted:
                self.cacheStatus = .none
            default:
                break
            }
        }
    }

    /// Navigates the visualization to the parent of the current root.
    func navigateToParent() {
        guard let vizState, let tree else { return }
        guard let currentNode = tree.node(at: vizState.currentRootIndex) else { return }
        if currentNode.parentIndex != UInt32.max && currentNode.parentIndex != vizState.currentRootIndex {
            vizState.drillDown(to: currentNode.parentIndex)
        }
    }
}
