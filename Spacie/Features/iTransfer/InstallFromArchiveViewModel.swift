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

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        app: ArchivedApp,
        service: any iMobileDeviceProtocol = KMPDeviceServiceAdapter()
    ) {
        self.app = app
        self.service = service
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
        installError = nil
        isInstalling = true
        installProgress = 0
        do {
            try await service.installIPA(udid: udid, ipaPath: app.ipaURL) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.installProgress = progress
                }
            }
            installDone = true
            stopObservingDevice()
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
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
