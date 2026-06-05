import SwiftUI

// MARK: - CacheCoordinatorContext

/// Surface of ``AppViewModel`` mutated by ``CacheCoordinator``.
///
/// Extracted as a narrow protocol so the coordinator does not depend on the
/// full AppViewModel surface and so unit tests can substitute a fake context
/// to verify cache load / save / WAL behaviour in isolation.
@MainActor
protocol CacheCoordinatorContext: AnyObject {
    var sizeMode: SizeMode { get }
    var tree: FileTree? { get set }
    var treeVersion: Int { get set }
    var vizState: VisualizationState? { get set }
    var scanState: ScanState { get set }
    var scanPhase: ScanPhase { get set }
    var lastScanDate: Date? { get set }
    var dataIsStale: Bool { get set }
    var cacheStatus: CacheStatus { get set }
}

// MARK: - CacheCoordinator

/// Owns the disk-cache lifecycle for ``AppViewModel``.
///
/// Extracted from `AppViewModel` (sprint refactor — 756 LOC god-class split).
/// Responsibilities:
///  * load the cached tree blob + WAL, apply patches, hand off to UI
///  * coordinate crash-recovery (interrupted Phase 1 / Phase 2 resumes)
///  * persist the current tree state via [saveCurrentStateToCache]
///  * schedule auto-dismiss of transient cache banners
///
/// Calls back into the [CacheCoordinatorContext] (the owning view model) to
/// mutate observable UI state. The coordinator never mutates the orchestrator
/// callbacks — that remains the view model's job, since callbacks are bound
/// to fresh closures per full scan.
@MainActor
final class CacheCoordinator {

    // MARK: - Dependencies

    private weak var context: (any CacheCoordinatorContext)?
    private let orchestrator: any ScanOrchestratorProtocol

    /// Background task for cache validation and auto-dismiss.
    private(set) var validationTask: Task<Void, Never>?
    /// Tracks the deferred dismiss task so `cancel()` / `cancelAndWait()`
    /// stop it from overwriting the cache banner of a freshly-started new
    /// scan. Without tracking, the orphan dismiss survived teardown and
    /// reset `context.cacheStatus = .none` after the new scan had already
    /// set its own status.
    private var dismissTask: Task<Void, Never>?

    // MARK: - Init

    init(orchestrator: any ScanOrchestratorProtocol, context: any CacheCoordinatorContext) {
        self.orchestrator = orchestrator
        self.context = context
    }

    // MARK: - Cancellation

    /// Cancels any in-flight validation / rescan task started by this coordinator.
    func cancel() {
        validationTask?.cancel()
        validationTask = nil
        dismissTask?.cancel()
        dismissTask = nil
    }

    /// Awaits the in-flight validation task (used by ``AppViewModel/rescan``).
    func cancelAndWait() async {
        validationTask?.cancel()
        dismissTask?.cancel()
        if let task = validationTask { _ = await task.value }
        validationTask = nil
        dismissTask = nil
    }

    // MARK: - Public API

    /// Attempts to load the scan from cache and start incremental validation
    /// or crash-recovery as appropriate.
    ///
    /// Returns `true` when the cache load took ownership of the scan (UI is
    /// either showing the cached tree or a transient status). Returns `false`
    /// when the caller should fall through to a full scan.
    func attemptCacheLoad(
        cache: ScanCache,
        configuration: ScanConfiguration
    ) async -> Bool {
        guard let context else { return false }

        // Verify the volume is still mounted / accessible before attempting
        // to load and validate the cache. Without this check, CacheValidator
        // would lstat() every cached directory, all would fail, and we'd
        // trigger a massive rescan destined to fail.
        let rootPath = configuration.rootPath.path(percentEncoded: false)
        guard FileManager.default.isReadableFile(atPath: rootPath) else {
            context.cacheStatus = .volumeNotMounted
            return true
        }

        // Deserialize the cache blob + prepare-for-patching + WAL replay all on
        // a background thread. Each of these is O(N) on the 5M-node tree and
        // previously ran on MainActor after `await loadTask.value` resumed,
        // producing a 5–10 s UI freeze on click. The tree is `@unchecked Sendable`
        // and is not yet visible to anyone else, so off-actor mutation is safe.
        let loadTask = Task.detached(priority: .userInitiated) { () -> FileTree? in
            guard let tree = cache.load() else { return nil }
            if cache.scanComplete {
                tree.prepareForPatching()
                Self.applyWALEntries(cache: cache, tree: tree)
            }
            return tree
        }
        guard let cachedTree = await loadTask.value else {
            context.cacheStatus = .corrupted
            cache.invalidate()
            scheduleCacheStatusDismiss(after: 3.0)
            return false
        }

        if !cache.scanComplete {
            return await handleIncompleteCache(
                cache: cache,
                cachedTree: cachedTree,
                configuration: configuration
            )
        }

        context.tree = cachedTree
        context.treeVersion += 1
        context.scanPhase = .green
        context.scanState = .completed(ScanStats(
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
            sizeMode: context.sizeMode
        )
        context.vizState = vs
        context.lastScanDate = cache.lastScanDate
        context.dataIsStale = false
        context.cacheStatus = .loadedChecking(lastScanDate: cache.lastScanDate ?? Date())

        validationTask?.cancel()
        validationTask = Task { [weak self, weak context] in
            guard let self, let context else { return }

            // Run CacheValidator OFF MainActor. validate() is `async` but not
            // `nonisolated`, so without Task.detached it inherits the caller's
            // MainActor isolation and freezes the UI during the O(N) directory
            // traversal in collectDirectories() on a 3.7M-node tree.
            let result = await Task.detached(priority: .userInitiated) {
                await CacheValidator().validate(
                    tree: cachedTree,
                    rootPath: rootPath
                )
            }.value

            if Task.isCancelled { return }

            if result.dirtyDirectories.isEmpty {
                context.cacheStatus = .upToDate
                self.scheduleCacheStatusDismiss(after: 3.0)
            } else {
                let rescanResult = await self.orchestrator.startIncrementalRescan(
                    cachedTree: cachedTree,
                    dirtyPaths: result.dirtyDirectories,
                    configuration: configuration,
                    cache: cache
                )

                if Task.isCancelled { return }

                context.tree = cachedTree
                context.treeVersion += 1
                context.cacheStatus = .changesFound(
                    addedBytes: rescanResult.bytesChanged,
                    dirCount: rescanResult.directoriesRescanned
                )

                let eventId = FSEventsMonitor.currentSystemEventId()
                try? cache.save(
                    tree: cachedTree,
                    scanComplete: true,
                    lastPhase: 2,
                    lastEventId: eventId
                )

                if cache.shouldCompact() {
                    Task.detached(priority: .utility) {
                        try? cache.compactWAL(tree: cachedTree, lastEventId: eventId)
                    }
                }

                self.scheduleCacheStatusDismiss(after: 5.0)
            }

            cache.startMonitoring(path: rootPath)
        }

        return true
    }

    /// Persists the current tree state to the cache. Called on app termination.
    /// Returns `true` if a cache record was written.
    @discardableResult
    func saveCurrentStateToCache(
        cache: ScanCache?,
        tree: FileTree?,
        scanPhase: ScanPhase
    ) -> Bool {
        guard let cache, let tree else { return false }

        let eventId = FSEventsMonitor.currentSystemEventId()
        let isComplete = scanPhase == .green || scanPhase == .smartGreen
        let phase: UInt8 = scanPhase == .red ? 0 : (scanPhase == .yellow ? 1 : 2)

        try? cache.save(
            tree: tree,
            scanComplete: isComplete,
            lastPhase: phase,
            lastEventId: eventId
        )
        return true
    }

    // MARK: - Private

    private func handleIncompleteCache(
        cache: ScanCache,
        cachedTree: FileTree,
        configuration: ScanConfiguration
    ) async -> Bool {
        guard let context else { return false }

        if cache.lastPhase <= 1 {
            cache.invalidate()
            return false
        }

        context.cacheStatus = .resumingScan

        // Same off-actor prep as in attemptCacheLoad — keep heavy O(N) work
        // off MainActor to avoid a UI hang on cached startup.
        await Task.detached(priority: .userInitiated) {
            cachedTree.prepareForPatching()
            Self.applyWALEntries(cache: cache, tree: cachedTree)
        }.value

        context.tree = cachedTree
        context.scanPhase = .yellow
        let vs = VisualizationState(
            rootIndex: cachedTree.rootIndex,
            sizeMode: context.sizeMode
        )
        vs.useEntryCount = false
        context.vizState = vs
        context.lastScanDate = cache.lastScanDate

        validationTask?.cancel()
        validationTask = Task { [weak self, weak context] in
            guard let self, let context else { return }

            let rootPath = configuration.rootPath.path(percentEncoded: false)
            // Same off-MainActor invariant as attemptCacheLoad — collectDirectories
            // is O(N) on millions of nodes and must not run on main.
            let result = await Task.detached(priority: .userInitiated) {
                await CacheValidator().validate(tree: cachedTree, rootPath: rootPath)
            }.value

            if Task.isCancelled { return }

            let dirtyPaths = result.dirtyDirectories
            if !dirtyPaths.isEmpty {
                _ = await self.orchestrator.startIncrementalRescan(
                    cachedTree: cachedTree,
                    dirtyPaths: dirtyPaths,
                    configuration: configuration,
                    cache: cache
                )

                if Task.isCancelled { return }
                context.tree = cachedTree
            }

            context.scanPhase = .green
            context.cacheStatus = .none
            context.lastScanDate = Date()

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

    nonisolated static func applyWALEntries(cache: ScanCache, tree: FileTree) {
        guard cache.wal.isValid(baseFormatVersion: ScanCache.currentFormatVersion) else {
            cache.wal.deleteWAL()
            return
        }

        guard let entries = try? cache.wal.readAll(), !entries.isEmpty else {
            return
        }

        for entry in entries {
            tree.applyWALPatch(
                dirPath: entry.dirPath,
                walNodes: entry.nodes,
                walStringPoolData: entry.stringPoolData
            )
        }

        tree.aggregateSizes()
    }

    private func scheduleCacheStatusDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak context] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            guard let context else { return }
            switch context.cacheStatus {
            case .upToDate, .changesFound, .corrupted:
                context.cacheStatus = .none
            default:
                break
            }
        }
    }
}
