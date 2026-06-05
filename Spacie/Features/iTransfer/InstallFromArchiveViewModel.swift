import Foundation

// MARK: - InstallFromArchiveViewModel

/// View model for ``InstallFromArchiveSheet``.
///
/// Owns the device observation task and the IPA installation lifecycle.
/// Service dependency is injected so tests / previews can substitute a
/// `MockiMobileDeviceService`. Previously the install logic lived inside the
/// view itself with a hard-coded `KMPDeviceServiceAdapter()` — this VM
/// extraction makes the flow unit-testable and previewable.
@MainActor
@Observable
final class InstallFromArchiveViewModel {

    // MARK: - State

    let app: ArchivedApp

    private(set) var device: DeviceInfo?
    private(set) var trustState: TrustState = .notTrusted

    private(set) var isInstalling = false
    private(set) var installProgress: Double = 0
    private(set) var installDone = false
    private(set) var installError: String?

    // MARK: - Dependencies

    private let service: any iMobileDeviceProtocol

    // Regular MainActor-isolated; cancelled from `isolated deinit` below.
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?
    /// Tracked so the install can be cancelled when the sheet is dismissed
    /// (otherwise the previous fire-and-forget pattern let the KMP install
    /// stream complete and mutate `installDone`/`installError` on an orphaned
    /// MainActor view-model — same defect class as the iTransfer trust update).
    @ObservationIgnored
    private var installTask: Task<Void, Error>?

    // MARK: - Init

    init(
        app: ArchivedApp,
        service: any iMobileDeviceProtocol = SharedDeviceServices.device
    ) {
        self.app = app
        self.service = service
    }

    isolated deinit {
        // Safety net: .onDisappear may not always fire when the sheet is
        // dismissed via cmd-W or app termination. Sync cancel from deinit
        // guarantees the device observation stream is released.
        observationTask?.cancel()
        installTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Begin polling for a connected iPhone. Cancels any previous observation.
    func startObservingDevice() {
        stopObservingDevice()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.observeDevices(pollingInterval: 2.0) {
                if Task.isCancelled { return }
                await self.handleEvent(event)
            }
        }
    }

    /// Stop observing devices (call from `.onDisappear`).
    func stopObservingDevice() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Computed flag for the install button enabled state.
    var canInstall: Bool {
        device != nil && trustState == .trusted && !isInstalling
    }

    // MARK: - Install

    /// Install [app] to the connected device.
    func beginInstall() async {
        guard let udid = device?.udid else { return }

        // Defer hoisted to function top so isInstalling/installTask reset
        // regardless of which early-return path the body takes. Placement
        // after the `for await` loop (the previous arrangement) worked
        // today but would silently break if anyone added another early
        // return above it.
        defer {
            installTask = nil
            isInstalling = false
        }

        installError = nil
        isInstalling = true
        installProgress = 0

        // Funnel off-actor progress callbacks through a single AsyncStream
        // instead of spawning one Task per update.
        let (progressStream, progressContinuation) = AsyncStream<Double>.makeStream()

        // Track the install task so deinit/cancellation can interrupt the
        // in-flight KMP installIPA stream.
        let task = Task {
            defer { progressContinuation.finish() }
            try await service.installIPA(udid: udid, ipaPath: app.ipaURL) { progress in
                progressContinuation.yield(progress)
            }
        }
        installTask = task

        for await progress in progressStream {
            if Task.isCancelled { break }
            installProgress = progress
        }

        do {
            _ = try await task.value
            if Task.isCancelled { return }
            installDone = true
            stopObservingDevice()
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            installError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func handleEvent(_ event: DeviceEvent) async {
        switch event {
        case .connected(let d):
            if device == nil {
                device = d
                trustState = .notTrusted
                let state = await service.validateTrust(udid: d.udid)
                if !Task.isCancelled {
                    trustState = state
                }
            }
        case .disconnected(let udid):
            if device?.udid == udid {
                device = nil
                trustState = .notTrusted
            }
        case .trustStateChanged(let udid, let state):
            if device?.udid == udid {
                trustState = state
            }
        case .error:
            break
        }
    }
}
