import SwiftUI

// MARK: - iTransferStep

/// Ordered steps of the iOS App Transfer wizard.
enum iTransferStep: Int, Comparable, CaseIterable, Sendable {
    case dependencyCheck = 0
    case connectSource
    case selectApps
    case chooseAction
    case connectDestination
    case transferring
    case result

    static func < (lhs: iTransferStep, rhs: iTransferStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - iTransferViewModel

/// Primary view model for the iOS App Transfer wizard.
///
/// Follows the same `@MainActor @Observable` pattern used by ``AppViewModel``.
/// The wizard advances linearly through ``iTransferStep`` cases, with each step
/// owning its own async work (dependency check, device polling, app list, transfer).
///
/// ## Lifecycle
/// 1. Initialised when the user navigates to the transfer feature.
/// 2. `checkDependencies()` is called automatically.
/// 3. User interacts step-by-step.
/// 4. `cancel()` terminates any in-flight async work and resets to the current step.
@MainActor
@Observable
final class iTransferViewModel {

    // MARK: - Step State

    var step: iTransferStep = .dependencyCheck

    // MARK: - Dependency Check (Step 1)

    var dependencyStatus: DependencyStatus?
    var installOutput: [String] = []
    var isInstallingDependencies = false

    // MARK: - Source Device (Step 2)

    var sourceDevice: DeviceInfo?
    var sourceTrustState: TrustState = .notTrusted
    var isWaitingForSource = false

    // MARK: - App Selection (Step 3)

    var availableApps: [AppInfo] = []
    var selectedBundleIDs: Set<String> = []
    var isLoadingApps = false

    // MARK: - Action Choice (Step 4)

    /// `true` → archive only. `false` → archive + install on destination.
    var archiveOnly = false
    /// Directory selected by the user for storing IPAs. `nil` until chosen.
    var archiveDir: URL?

    // MARK: - Destination Device (Step 5)

    var destinationDevice: DeviceInfo?
    var destinationTrustState: TrustState = .notTrusted
    var isWaitingForDestination = false

    // MARK: - Transfer (Step 6)

    var transferProgress: TransferProgress?

    // MARK: - Result (Step 7)

    var transferResult: TransferResult?

    // MARK: - Apple ID Auth (Part of Dependency Check)

    /// Whether ipatool is currently authenticated with a valid Apple ID session.
    var appleIDAuthenticated: Bool = false

    /// `true` while `ipatool auth info` is running.
    var isCheckingAppleID = false

    /// `true` while `ipatool auth login` is running.
    var isAuthenticatingAppleID = false

    /// Localized error message from the last failed sign-in attempt.
    var appleIDLoginError: String?

    /// `true` after first login attempt revealed 2FA is required.
    /// UI switches to show the verification code field only.
    var appleIDNeedsTwoFactor = false

    /// Email remembered between the two 2FA steps so it can be shown in the UI.
    var appleIDEmailForTwoFactor = ""

    // MARK: - General Error

    var lastError: String?

    // MARK: - Dependencies

    private let service: any iMobileDeviceProtocol
    private let archiveService: any AppArchiveProtocol

    private var deviceObservationTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?

    // MARK: - Init

    init(
        service: any iMobileDeviceProtocol = KMPDeviceServiceAdapter(),
        archiveService: any AppArchiveProtocol = AppArchiveService()
    ) {
        self.service = service
        self.archiveService = archiveService
    }

    // MARK: - Step 1: Dependency Check

    func checkDependencies() async {
        dependencyStatus = nil
        lastError = nil
        let status = await service.checkDependencies()
        dependencyStatus = status
        if case .ready = status {
            // Also verify Apple ID authentication before advancing.
            await checkAppleIDStatus()
            if appleIDAuthenticated {
                step = .connectSource
            }
        }
    }

    func installDependencies() async {
        guard !isInstallingDependencies else { return }
        isInstallingDependencies = true
        installOutput = []
        lastError = nil

        do {
            try await service.installDependencies { [weak self] line in
                Task { @MainActor [weak self] in
                    self?.installOutput.append(line)
                }
            }
            let status = await service.checkDependencies()
            dependencyStatus = status
            if case .ready = status {
                // Must also check Apple ID before advancing, same as checkDependencies().
                await checkAppleIDStatus()
                if appleIDAuthenticated {
                    step = .connectSource
                }
                // If not authenticated, stays on Setup and shows Apple ID form.
            }
        } catch {
            lastError = error.localizedDescription
        }

        isInstallingDependencies = false
    }

    // MARK: - Apple ID Auth Helpers

    /// Queries ipatool for an active session and updates ``appleIDAuthenticated``.
    func checkAppleIDStatus() async {
        isCheckingAppleID = true
        appleIDAuthenticated = await service.checkAppleIDAuth()
        isCheckingAppleID = false
    }

    /// Step 1: attempt login with email + password only.
    /// If 2FA is required, sets `appleIDNeedsTwoFactor = true` so the UI can
    /// show the verification-code field as a second step.
    func loginAppleID(email: String, password: String) async {
        isAuthenticatingAppleID = true
        appleIDLoginError = nil
        appleIDNeedsTwoFactor = false
        do {
            try await service.loginAppleID(email: email, password: password, authCode: nil)
            appleIDAuthenticated = true
            appleIDEmailForTwoFactor = ""
            step = .connectSource
        } catch iMobileDeviceError.twoFactorRequired {
            // Apple sent a 2FA code to the user's devices — keep the form open.
            appleIDNeedsTwoFactor = true
            appleIDEmailForTwoFactor = email
        } catch {
            appleIDLoginError = error.localizedDescription
        }
        isAuthenticatingAppleID = false
    }

    /// Step 2: re-login with the 2FA code the user received on their devices.
    func loginAppleIDWithTwoFactor(email: String, password: String, code: String) async {
        isAuthenticatingAppleID = true
        appleIDLoginError = nil
        do {
            try await service.loginAppleID(email: email, password: password, authCode: code)
            appleIDAuthenticated = true
            appleIDNeedsTwoFactor = false
            appleIDEmailForTwoFactor = ""
            step = .connectSource
        } catch {
            appleIDLoginError = error.localizedDescription
        }
        isAuthenticatingAppleID = false
    }

    func cancelAppleIDLogin() {
        appleIDNeedsTwoFactor = false
        appleIDLoginError = nil
        appleIDEmailForTwoFactor = ""
    }

    // MARK: - Step 2: Connect Source

    func startSourceDeviceObservation() {
        stopDeviceObservation()
        isWaitingForSource = true
        deviceObservationTask = Task {
            for await event in service.observeDevices(pollingInterval: 2.0) {
                handleDeviceEvent(event, role: .source)
                if sourceDevice != nil, sourceTrustState == .trusted {
                    break
                }
            }
            isWaitingForSource = false
            await loadSourceApps()
            if !availableApps.isEmpty || lastError != nil {
                step = .selectApps
            }
        }
    }

    func stopDeviceObservation() {
        deviceObservationTask?.cancel()
        deviceObservationTask = nil
    }

    // MARK: - Step 3: Select Apps

    func loadSourceApps() async {
        guard let udid = sourceDevice?.udid else { return }
        isLoadingApps = true
        lastError = nil
        do {
            availableApps = try await service.listApps(udid: udid)
        } catch {
            lastError = error.localizedDescription
        }
        isLoadingApps = false
    }

    func toggleAppSelection(_ bundleID: String) {
        if selectedBundleIDs.contains(bundleID) {
            selectedBundleIDs.remove(bundleID)
        } else {
            selectedBundleIDs.insert(bundleID)
        }
    }

    func selectAllApps() {
        selectedBundleIDs = Set(availableApps.map(\.bundleID))
    }

    func deselectAllApps() {
        selectedBundleIDs = []
    }

    // MARK: - Step 4: Choose Action

    func chooseArchiveOnly() {
        archiveOnly = true
    }

    func chooseArchiveAndInstall() {
        archiveOnly = false
    }

    /// Presents the directory picker via `NSOpenPanel`.
    func selectArchiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Archive Folder"
        panel.message = "Select where to save the extracted IPA files."

        if panel.runModal() == .OK {
            archiveDir = panel.url
        }
    }

    func proceedFromChooseAction() {
        if archiveOnly {
            step = .transferring
        } else {
            step = .connectDestination
        }
    }

    // MARK: - Step 5: Connect Destination

    func startDestinationDeviceObservation() {
        stopDeviceObservation()
        isWaitingForDestination = true
        deviceObservationTask = Task {
            for await event in service.observeDevices(pollingInterval: 2.0) {
                handleDeviceEvent(event, role: .destination)
                if destinationDevice != nil, destinationTrustState == .trusted {
                    break
                }
            }
        }
    }

    // MARK: - Step 6: Transfer

    func startTransfer() {
        guard let sourceUDID = sourceDevice?.udid else { return }

        let selectedApps = availableApps.filter { selectedBundleIDs.contains($0.bundleID) }
        guard !selectedApps.isEmpty else { return }

        let destUDID: String? = archiveOnly ? nil : destinationDevice?.udid
        let dir = archiveDir ?? archiveService.archiveDirectory
        transferProgress = nil
        lastError = nil

        transferTask = Task {
            let stream = service.transferApps(
                sourceUDID: sourceUDID,
                destinationUDID: destUDID,
                apps: selectedApps,
                archiveDir: dir,
                shouldInstall: !archiveOnly
            )
            do {
                for try await progress in stream {
                    transferProgress = progress
                }
                buildTransferResult(from: selectedApps)
            } catch {
                lastError = error.localizedDescription
                buildTransferResult(from: selectedApps)
            }
            step = .result
        }
    }

    func cancelTransfer() {
        transferTask?.cancel()
        transferTask = nil
    }

    // MARK: - General

    func reset() {
        cancelTransfer()
        stopDeviceObservation()
        step = .dependencyCheck
        dependencyStatus = nil
        installOutput = []
        isInstallingDependencies = false
        appleIDAuthenticated = false
        isCheckingAppleID = false
        isAuthenticatingAppleID = false
        appleIDLoginError = nil
        sourceDevice = nil
        sourceTrustState = .notTrusted
        isWaitingForSource = false
        availableApps = []
        selectedBundleIDs = []
        isLoadingApps = false
        archiveOnly = true
        archiveDir = nil
        destinationDevice = nil
        destinationTrustState = .notTrusted
        isWaitingForDestination = false
        transferProgress = nil
        transferResult = nil
        lastError = nil
    }

    // MARK: - Computed Helpers

    var selectedAppsCount: Int { selectedBundleIDs.count }

    var canProceedFromSelectApps: Bool { !selectedBundleIDs.isEmpty }

    var canProceedFromChooseAction: Bool {
        archiveOnly || !archiveOnly  // always true; archiveDir optional (defaults to app support)
    }

    // MARK: - Private

    private enum DeviceRole { case source, destination }

    private func handleDeviceEvent(_ event: DeviceEvent, role: DeviceRole) {
        switch event {
        case .connected(let device):
            if role == .source, sourceDevice == nil {
                sourceDevice = device
                sourceTrustState = .notTrusted
                Task {
                    let state = await service.validateTrust(udid: device.udid)
                    sourceTrustState = state
                }
            } else if role == .destination, destinationDevice == nil,
                      device.udid != sourceDevice?.udid {  // Never reuse the source phone as destination
                destinationDevice = device
                destinationTrustState = .notTrusted
                Task {
                    let state = await service.validateTrust(udid: device.udid)
                    destinationTrustState = state
                    if state == .trusted && step == .connectDestination {
                        step = .transferring
                    }
                }
            }

        case .disconnected(let udid):
            if role == .source, sourceDevice?.udid == udid {
                sourceDevice = nil
                sourceTrustState = .notTrusted
            } else if role == .destination, destinationDevice?.udid == udid {
                destinationDevice = nil
                destinationTrustState = .notTrusted
            }

        case .trustStateChanged(let udid, let state):
            if sourceDevice?.udid == udid {
                sourceTrustState = state
                if state == .trusted, step == .connectSource {
                    Task {
                        // Re-fetch device info now that trust is granted so the
                        // device name/version replace the "Unknown" placeholders.
                        if let updated = try? await service.listDevices().first(where: { $0.udid == udid }) {
                            sourceDevice = updated
                        }
                    }
                }
            } else if destinationDevice?.udid == udid {
                destinationTrustState = state
                if state == .trusted, step == .connectDestination {
                    Task {
                        if let updated = try? await service.listDevices().first(where: { $0.udid == udid }) {
                            destinationDevice = updated
                        }
                        step = .transferring
                    }
                }
            }

        case .error:
            break
        }
    }

    private func buildTransferResult(from apps: [AppInfo]) {
        guard let progress = transferProgress else {
            transferResult = TransferResult(items: apps.map {
                TransferItemResult(id: $0.bundleID, app: $0, success: false, archivedURL: nil, error: .cancelled)
            })
            return
        }

        let results = progress.items.map { item in
            TransferItemResult(
                id: item.id,
                app: item.app,
                success: item.phase == .completed,
                archivedURL: nil,
                error: item.error
            )
        }
        transferResult = TransferResult(items: results)
    }
}
