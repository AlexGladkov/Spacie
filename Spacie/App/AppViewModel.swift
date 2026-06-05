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

    private let orchestrator: any ScanOrchestratorProtocol
    private var scanTask: Task<Void, Never>?
    /// Tracked so successive Move-to-Trash invocations cancel the previous
    /// aggregate pass instead of stacking up overlapping detached tasks that
    /// would race each other's treeVersion bump.
    private var trashAggregateTask: Task<Void, Never>?

    /// Persistent scan cache instance for the current volume.
    /// Created lazily when a scan starts or cache is loaded.
    private(set) var scanCache: ScanCache?

    /// Whether a cache file exists on disk for the current volume.
    ///
    /// Stored rather than computed so it is safe to read from SwiftUI body closures
    /// without triggering filesystem I/O (which caused a performance regression where
    /// every progress-update re-render performed `createDirectory` + `stat`).
    private(set) var cacheExistsForVolume: Bool = false

    /// Cache lifecycle coordinator (load, WAL replay, save, dismiss banners).
    /// Extracted from this view model to keep the scan-orchestration code below
    /// focused; mutations to UI state happen via the [CacheCoordinatorContext]
    /// protocol implemented in an extension on this class.
    @ObservationIgnored
    private var cacheCoordinator: CacheCoordinator!

    /// Prevents App Nap from throttling the scan while in background.
    private var scanActivity: NSObjectProtocol?

    // MARK: - Initialization

    init(orchestrator: any ScanOrchestratorProtocol = ScanOrchestrator()) {
        let savedSize = UserDefaults.standard.string(forKey: "defaultSizeMode") ?? SizeMode.logical.rawValue
        self.sizeMode = SizeMode(rawValue: savedSize) ?? .logical
        self.orchestrator = orchestrator

        // Register defaults for Smart Scan settings.
        UserDefaults.standard.register(defaults: [
            "smartScanEnabled": true,
            "smartScanCoverageThreshold": 0.95,
        ])

        self.cacheCoordinator = CacheCoordinator(orchestrator: orchestrator, context: self)
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

        // Show a "preparing" placeholder immediately so the user sees the
        // disk-click → results transition. Without this, scanState stayed
        // .idle for the duration of attemptCacheLoad (5-10s on big disks)
        // and the UI looked frozen on the volume picker.
        scanState = .preparing("Loading scan data…")

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
            let loaded = await cacheCoordinator.attemptCacheLoad(cache: cache, configuration: configuration)
            if loaded {
                endScanActivity()
                return
            }
        }

        // No cache or cache load failed: run full scan.
        // Preserve `.corrupted` so the user actually sees the explanatory
        // banner — overwriting it with `.none` instantly hid the notice
        // and made cache corruption silently look like a normal cold scan.
        if cacheStatus != .corrupted {
            cacheStatus = .none
        }
        await startFullScan(volume: volume, configuration: configuration)
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

                    // Step 10: Save cache after Phase 1 completion.
                    // Offload to a detached task — `cache.save` writes a large
                    // serialized tree to disk synchronously and previously
                    // stalled the MainActor at the Phase1→Yellow handoff for
                    // 5M-node volumes.
                    if let cache = self.scanCache {
                        let eventId = FSEventsMonitor.currentSystemEventId()
                        Task.detached(priority: .utility) {
                            try? cache.save(
                                tree: tree,
                                scanComplete: false,
                                lastPhase: 1,
                                lastEventId: eventId
                            )
                        }
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
            let stats = await self.orchestrator.startScan(configuration: configuration)
            // Smart Scan exits with nil stats by design (results live in
            // smartScanResult on the orchestrator). The previous flow only
            // updated scanState when stats was non-nil, so a successful
            // Smart Scan completion left scanState stuck on .scanning(...),
            // and the UI never showed "complete".
            if let stats {
                self.scanState = .completed(stats)
                self.scanStartDate = nil
                self.lastScanDate = Date()
                self.dataIsStale = false
                self.scanPhase = .green
                // Clear the "cache corrupted" banner after the recovery
                // full-scan finishes — without this, the warning persisted
                // for the entire visualisation session and confused users
                // about the new scan's validity.
                if self.cacheStatus == .corrupted {
                    self.cacheStatus = .none
                }
                // Final tree swap to the fully accurate deep tree.
                if let deepTree = self.orchestrator.deepTree {
                    self.tree = deepTree
                    self.treeVersion += 1

                    // Step 10: Save cache after Phase 2 completion. The
                    // serialize-and-write is offloaded; FSEvents monitoring
                    // (cheap to start) stays on main to avoid races with
                    // teardown reading `cache.monitor`.
                    if let cache = self.scanCache {
                        let eventId = FSEventsMonitor.currentSystemEventId()
                        let rootPath = configuration.rootPath.path(percentEncoded: false)
                        Task.detached(priority: .utility) {
                            try? cache.save(
                                tree: deepTree,
                                scanComplete: true,
                                lastPhase: 2,
                                lastEventId: eventId
                            )
                            cache.wal.deleteWAL()
                        }
                        cache.startMonitoring(path: rootPath)
                    }
                }
            } else if Task.isCancelled {
                self.scanState = .cancelled
            } else if let smartResult = self.orchestrator.smartScanResult {
                // Smart Scan reached its coverage threshold and the
                // orchestrator already moved phase to .smartGreen. Synthesize
                // a completed ScanStats from the partial-coverage data so
                // the UI exits the .scanning state. Without this, scanState
                // stayed stuck on `.scanning(...)` even though phase was
                // already .smartGreen and onProgress had stopped firing.
                self.scanState = .completed(ScanStats(
                    totalFiles: 0,
                    totalDirectories: 0,
                    totalLogicalSize: smartResult.scannedBytes,
                    totalPhysicalSize: smartResult.scannedBytes,
                    restrictedDirectories: 0,
                    skippedDirectories: UInt64(smartResult.unscannedDirectoryCount),
                    scanDuration: 0,
                    volumeId: configuration.volumeId
                ))
                self.scanStartDate = nil
                self.lastScanDate = Date()
                self.dataIsStale = false
                // Mirror the full-scan path: clear the corrupted-cache
                // banner once the smart scan completes; otherwise the
                // warning persisted forever for users on Smart Scan mode.
                if self.cacheStatus == .corrupted {
                    self.cacheStatus = .none
                }
            }
            self.endScanActivity()
        }
    }

    /// Cancels the currently running scan, if any.
    func cancelScan() {
        orchestrator.cancel()
        // Detach orchestrator callbacks so a late-firing event from the
        // cancelled task cannot resurrect `scanState = .scanning(...)` over
        // the freshly-cancelled UI state. Without this, the throttled
        // onProgress closure could re-fire after we transition to .cancelled.
        orchestrator.onPhaseChange = nil
        orchestrator.onProgress = nil
        orchestrator.onTreeUpdate = nil
        orchestrator.onRestricted = nil
        scanTask?.cancel()
        scanTask = nil
        cacheCoordinator.cancel()
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

        // Serialize repeated Move-to-Trash calls. Cancelling the previous
        // task is not enough on its own — `Task.cancel()` is cooperative
        // and the inner `Task.detached` may already be in the middle of
        // `tree.removeNode`/`aggregateSizes`. Await the previous handle so
        // a fresh trash never runs concurrently with a still-active
        // FileTree mutation from the prior invocation.
        let previous = trashAggregateTask
        previous?.cancel()
        trashAggregateTask = Task { [tree] in
            _ = await previous?.value
            // Check cancellation BEFORE the detached mutation runs.
            // Otherwise a cancel issued during the await above still let
            // us proceed to mutate the tree and only bailed afterwards.
            if Task.isCancelled { return }

            let deletedBytes = await Task.detached(priority: .userInitiated) { () -> UInt64 in
                let bytes = tree.removeNode(at: index)
                tree.aggregateSizes()
                return bytes
            }.value

            if Task.isCancelled { return }
            treeVersion += 1

            // Notify orchestrator (Smart Scan rescan trigger)
            if let volume, deletedBytes > 0 {
                orchestrator.handleDeletion(deletedBytes: deletedBytes, volume: volume.mountPoint)
            }

            // After a trash, the on-disk state has just changed but the
            // in-memory tree was already mutated to match — therefore the
            // tree is *not* stale relative to disk. But FSEvents may still
            // surface additional unrelated changes; keep the stale flag
            // monotonically truthful by leaving it alone here (was
            // `dataIsStale = false`, which silently hid legitimate
            // FSEvents-detected staleness from other sources).
        }
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
        // Show transitional placeholder while we drain the previous run.
        // cancelAndWait + orchestrator.cancelAndWait can take 1-3 seconds
        // on big trees; without this the UI looked frozen.
        scanState = .preparing("Preparing rescan…")

        // 1. Cancel and wait for everything in flight to actually exit.
        // Capture the handle BEFORE cancelScan() — cancelScan() nils
        // `scanTask`, so reading it afterwards would always be nil and the
        // await would silently no-op, letting the previous scan's resume
        // race with the new scan started below.
        let runningTask = scanTask
        cancelScan()
        if let task = runningTask { _ = await task.value }
        await cacheCoordinator.cancelAndWait()
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
        let saved = cacheCoordinator.saveCurrentStateToCache(
            cache: scanCache,
            tree: tree,
            scanPhase: scanPhase
        )
        if saved {
            cacheExistsForVolume = true
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

// MARK: - CacheCoordinatorContext

/// Exposes the subset of [AppViewModel] properties that ``CacheCoordinator``
/// mutates during cache load / save / WAL replay flows. All required members
/// are already declared on the view model — this conformance is just the
/// protocol wiring and intentionally adds no new behaviour.
extension AppViewModel: CacheCoordinatorContext {}
