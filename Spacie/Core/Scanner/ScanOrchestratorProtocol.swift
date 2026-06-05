import Foundation

// MARK: - ScanOrchestratorProtocol

/// Surface of ``ScanOrchestrator`` consumed by ``AppViewModel`` and
/// ``CacheCoordinator``.
///
/// Extracted so the view model can be unit-tested against a fake orchestrator
/// without spinning up the full two-phase scan pipeline. Methods and
/// observable properties match the concrete ``ScanOrchestrator`` 1:1; new
/// orchestrator features should be added here in lockstep.
///
/// Only members exercised by the view model + cache coordinator are exposed —
/// internal phase machinery (`runPhase1`, `runPhase2`, throttling helpers) is
/// intentionally not part of the protocol.
@MainActor
protocol ScanOrchestratorProtocol: AnyObject {

    // -- Smart Scan + cache plumbing --

    /// Mirrors ``ScanOrchestrator/smartScanSettings``.
    var smartScanSettings: SmartScanSettings? { get set }

    /// Mirrors ``ScanOrchestrator/scanCache``.
    var scanCache: ScanCache? { get set }

    // -- Read-only tree state --

    /// Tree currently being visualized (shallow during Phase 2, deep otherwise).
    var activeTree: FileTree? { get }

    /// Deep tree from Phase 2 once complete.
    var deepTree: FileTree? { get }

    /// Smart-scan partial-coverage result, set when the orchestrator
    /// short-circuited Phase 2 at the configured coverage threshold.
    /// Consumed by AppViewModel to drive the scan-state transition out of
    /// `.scanning(...)` even when `startScan` returned nil stats.
    var smartScanResult: SmartScanResult? { get }

    /// Current phase published by the orchestrator (mirror of internal state).
    var phase: ScanPhase { get }

    // -- Callbacks --

    var onPhaseChange: ((ScanPhase) -> Void)? { get set }
    var onProgress: ((ScanProgress) -> Void)? { get set }
    var onTreeUpdate: ((FileTree) -> Void)? { get set }
    var onRestricted: (() -> Void)? { get set }

    // -- Lifecycle --

    func startScan(configuration: ScanConfiguration) async -> ScanStats?

    func startIncrementalRescan(
        cachedTree: FileTree,
        dirtyPaths: [String],
        configuration: ScanConfiguration,
        cache: ScanCache
    ) async -> IncrementalRescanResult

    func cancel()

    func cancelAndWait() async

    func handleDeletion(deletedBytes: UInt64, volume: URL)
}

// MARK: - Conformance

/// The concrete ``ScanOrchestrator`` already exposes the full protocol surface,
/// so conformance is structural and adds no new behaviour.
extension ScanOrchestrator: ScanOrchestratorProtocol {}
