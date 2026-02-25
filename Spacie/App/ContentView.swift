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
            volumeId: volume.id
        )

        // Try the incremental cache path first
        let cache = ScanCache(volumeId: volume.id)
        self.scanCache = cache
        orchestrator.scanCache = cache

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
            self?.scanState = .scanning(progress)
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

    /// Discards the current tree and rescans the same volume from scratch.
    func rescan() async {
        tree = nil
        vizState = nil
        scanState = .idle
        scanPhase = .red
        dataIsStale = false
        cacheStatus = .none
        // Invalidate the cache so a full scan is performed
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

// MARK: - ContentView

/// Root view for a single Spacie window/tab.
///
/// Displays one of three screens depending on the scan state:
/// 1. **Start screen** -- a grid of available volumes when no scan is active.
/// 2. **Scanning screen** -- live progress during a scan.
/// 3. **Results screen** -- visualization and feature panels after a scan completes.
struct ContentView: View {

    @State private var viewModel = AppViewModel()
    @Environment(VolumeManager.self) private var volumeManager
    @Environment(PermissionManager.self) private var permissionManager
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // FDA banner
            if viewModel.showFDABanner && !permissionManager.hasFullDiskAccess {
                fdaBanner
            }

            // Main content
            mainContent
        }
        .toolbar { toolbarContent }
        .navigationTitle(navigationTitle)
        .onReceive(NotificationCenter.default.publisher(for: .spacieRescan)) { _ in
            Task { await viewModel.rescan() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateBack)) { _ in
            viewModel.vizState?.navigateBack()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateForward)) { _ in
            viewModel.vizState?.navigateForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieNavigateParent)) { _ in
            viewModel.navigateToParent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieGoToFolder)) { _ in
            viewModel.showGoToFolder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .spacieSaveCacheOnTerminate)) { _ in
            viewModel.saveCurrentStateToCache()
        }
        .sheet(isPresented: $viewModel.showGoToFolder) {
            goToFolderSheet
        }
        .task {
            // Auto-start scan on boot volume when no volume is selected
            try? await Task.sleep(for: .seconds(0.5))
            if viewModel.volume == nil {
                if let bootVol = volumeManager.volumes.first(where: { $0.isBoot }) {
                    viewModel.volume = bootVol
                    await viewModel.startScan()
                }
            }
        }
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        if let volume = viewModel.volume {
            return volume.name
        }
        return "Spacie"
    }

    // MARK: - FDA Banner

    private var fdaBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(SpacieColors.warningForeground)
            Text("Some directories are restricted. Grant Full Disk Access for a complete scan.")
                .font(.callout)
            Spacer()
            Button("Open Settings") {
                permissionManager.openFullDiskAccessSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                withAnimation { viewModel.showFDABanner = false }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SpacieColors.warningBackground)
    }

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.scanState {
        case .idle:
            startScreen

        case .scanning(let progress):
            if progress.phase == .red {
                scanningScreen(progress: progress)
            } else {
                // Yellow phase -- show results screen with approximate data.
                resultsScreen
            }

        case .completed:
            resultsScreen

        case .cancelled:
            startScreen

        case .error(let message):
            errorScreen(message: message)
        }
    }

    // MARK: - Start Screen

    private var startScreen: some View {
        VolumePickerView(volumes: volumeManager.volumes) { volume in
            viewModel.volume = volume
            Task { await viewModel.startScan() }
        }
    }

    // MARK: - Scanning Screen

    /// Scanning progress screen shown during Phase 1 (Red) -- fast directory traversal.
    private func scanningScreen(progress: ScanProgress) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)

                Text("Scanning directory structure...")
                    .font(.headline)

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 20) {
                        Label(progress.directoriesScanned.formattedCount + " directories", systemImage: "folder")
                        Label(scanElapsed(at: context.date).formattedDuration, systemImage: "clock")
                        if progress.skippedDirectories > 0 {
                            Label(progress.skippedDirectories.formattedCount + " skipped", systemImage: "eye.slash")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 500)

                Button("Cancel") {
                    viewModel.cancelScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()

            Spacer()

            InfoBarView(viewModel: viewModel)
        }
    }

    /// Wall-clock elapsed time since the scan started.
    private func scanElapsed(at now: Date) -> TimeInterval {
        guard let start = viewModel.scanStartDate else { return 0 }
        return now.timeIntervalSince(start)
    }

    // MARK: - Results Screen

    private var resultsScreen: some View {
        VStack(spacing: 0) {
            // Main panel
            panelContent
                .id(viewModel.activePanel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Info bar
            InfoBarView(viewModel: viewModel)
        }
    }

    // MARK: - Panel Content

    @ViewBuilder
    private var panelContent: some View {
        switch viewModel.activePanel {
        case .visualization:
            visualizationPlaceholder
        case .largeFiles:
            LargeFilesView(
                viewModel: viewModel.largeFilesVM,
                tree: viewModel.tree,
                sizeMode: viewModel.sizeMode
            )
            .onAppear {
                if let tree = viewModel.tree {
                    viewModel.largeFilesVM.refresh(tree: tree, sizeMode: viewModel.sizeMode)
                }
            }
            .onChange(of: viewModel.sizeMode) { _, newMode in
                if let tree = viewModel.tree {
                    viewModel.largeFilesVM.refresh(tree: tree, sizeMode: newMode)
                }
            }
        case .duplicates:
            placeholderPanel(name: "Duplicates", icon: "doc.on.doc.fill")
        case .smartCategories:
            placeholderPanel(name: "Smart Categories", icon: "wand.and.stars")
        case .oldFiles:
            placeholderPanel(name: "Old Files", icon: "clock.fill")
        }
    }

    /// Split-layout browser: folder list on the left, file type distribution on the right.
    @ViewBuilder
    private var visualizationPlaceholder: some View {
        if let tree = viewModel.tree, let vizState = viewModel.vizState {
            VStack(spacing: 0) {
                BreadcrumbView(tree: tree, state: vizState)
                Divider()
                StorageBrowserView(
                    tree: tree,
                    state: vizState,
                    sizeMode: viewModel.sizeMode,
                    treeVersion: viewModel.treeVersion
                )
            }
        } else {
            ContentUnavailableView("No scan data", systemImage: "questionmark.circle")
        }
    }

    /// Generic placeholder for panels implemented by other agents.
    private func placeholderPanel(name: String, icon: String) -> some View {
        ContentUnavailableView(name, systemImage: icon, description: Text("Panel will be connected when implemented"))
    }

    // MARK: - Error Screen

    private func errorScreen(message: String) -> some View {
        ContentUnavailableView {
            Label("Scan Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") {
                Task { await viewModel.rescan() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Go to Folder Sheet

    private var goToFolderSheet: some View {
        VStack(spacing: 16) {
            Text("Go to Folder")
                .font(.headline)

            TextField("Enter path...", text: $viewModel.goToFolderPath)
                .textFieldStyle(.roundedBorder)
                .frame(width: 400)
                .onSubmit {
                    performGoToFolder()
                }

            HStack {
                Button("Cancel") {
                    viewModel.showGoToFolder = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Go") {
                    performGoToFolder()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.goToFolderPath.isEmpty)
            }
        }
        .padding(24)
    }

    private func performGoToFolder() {
        let path = (viewModel.goToFolderPath as NSString).expandingTildeInPath
        if let tree = viewModel.tree, let vizState = viewModel.vizState {
            // Linear search for the node matching the requested path.
            // FileTree does not expose a path-based index, so we iterate nodes.
            for i in 1...UInt32(tree.nodeCount) {
                if tree.fullPath(of: i) == path {
                    vizState.drillDown(to: i)
                    break
                }
            }
        }
        viewModel.showGoToFolder = false
        viewModel.goToFolderPath = ""
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Volume picker
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(volumeManager.volumes) { vol in
                    Button {
                        viewModel.volume = vol
                        Task { await viewModel.startScan() }
                    } label: {
                        Label(vol.name, systemImage: volumeIcon(for: vol))
                    }
                }
            } label: {
                Label(viewModel.volume?.name ?? "Select Volume", systemImage: "internaldrive")
            }
        }

        // Scan / Stop
        ToolbarItem(placement: .primaryAction) {
            if viewModel.scanState.isScanning {
                Button {
                    viewModel.cancelScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    Task { await viewModel.startScan() }
                } label: {
                    Label("Scan", systemImage: "play.fill")
                }
                .disabled(viewModel.volume == nil)
            }
        }

        // Size mode
        ToolbarItem {
            Picker("Size", selection: $viewModel.sizeMode) {
                ForEach(SizeMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
        }

        // Panel picker
        ToolbarItem {
            Picker("Panel", selection: $viewModel.activePanel) {
                ForEach(ActivePanel.allCases) { panel in
                    Label(panel.displayName, systemImage: panel.systemImage).tag(panel)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }

        // Search
        ToolbarItem {
            TextField("Search...", text: $viewModel.searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }

        // Settings
        ToolbarItem {
            Menu {
                Button("Open Settings...") {
                    openSettings()
                }

                if let volume = viewModel.volume,
                   ScanCache(volumeId: volume.id).cacheExists {
                    Divider()
                    Button("Clear Cache for \"\(volume.name)\"", role: .destructive) {
                        let cache = ScanCache(volumeId: volume.id)
                        cache.invalidate()
                        viewModel.cacheStatus = .none
                    }
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuIndicator(.hidden)
            .help("Settings")
        }
    }

    // MARK: - Helpers

    private func volumeIcon(for volume: VolumeInfo) -> String {
        switch volume.volumeType {
        case .internal: "internaldrive"
        case .external: "externaldrive"
        case .network: "network"
        case .disk_image: "opticaldisc"
        }
    }
}
