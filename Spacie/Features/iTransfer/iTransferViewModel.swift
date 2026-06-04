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
/// Sprint 4.5 rewrite — replaces the previous flat collection of 20+
/// `@Observable` fields (with the impossible-state combinations the audit
/// flagged) with a single [iTransferState] enum + cumulative [wizardData].
/// View code keeps reading the old top-level properties via computed
/// accessors so the rewrite stays binary-compatible with the step views.
@MainActor
@Observable
final class iTransferViewModel {

    // MARK: - State

    /// Strongly typed wizard state. The variant indicates the current step;
    /// its associated value carries only step-local flags (e.g. polling
    /// active).
    var state: iTransferState = .dependencyCheck(DependencyCheckSubstate())

    /// Cumulative wizard data that persists across step transitions.
    /// Mutating fields on this struct fires a single Observable update.
    var wizardData = iTransferWizardData()

    // MARK: - Dependencies

    private let service: any iMobileDeviceProtocol
    private let archiveService: any AppArchiveProtocol

    @ObservationIgnored
    private var deviceObservationTask: Task<Void, Never>?
    @ObservationIgnored
    private var transferTask: Task<Void, Never>?

    // MARK: - Init

    init(
        service: any iMobileDeviceProtocol = KMPDeviceServiceAdapter(),
        archiveService: any AppArchiveProtocol = AppArchiveService()
    ) {
        self.service = service
        self.archiveService = archiveService
    }

    // MARK: - Back-compat accessors (read paths)
    //
    // Step views were written against flat top-level properties. Keep those
    // accessors as computed properties so views compile unchanged. Each one
    // delegates to [state] or [wizardData].

    var step: iTransferStep { state.kind }

    var dependencyStatus: DependencyStatus? { wizardData.dependencyStatus }
    var installOutput: [String] { wizardData.installOutput }
    var isInstallingDependencies: Bool {
        if case .dependencyCheck(let sub) = state { return sub.isInstallingDependencies }
        return false
    }

    var sourceDevice: DeviceInfo? { wizardData.sourceDevice }
    var sourceTrustState: TrustState { wizardData.sourceTrustState }
    var isWaitingForSource: Bool {
        if case .connectSource(let sub) = state { return sub.isWaiting }
        return false
    }

    var availableApps: [AppInfo] {
        get { wizardData.availableApps }
        set { wizardData.availableApps = newValue }
    }
    var selectedBundleIDs: Set<String> {
        get { wizardData.selectedBundleIDs }
        set { wizardData.selectedBundleIDs = newValue }
    }
    var isLoadingApps: Bool {
        if case .selectApps(let sub) = state { return sub.isLoadingApps }
        return false
    }

    var archiveOnly: Bool {
        get { wizardData.archiveOnly }
        set { wizardData.archiveOnly = newValue }
    }
    var archiveDir: URL? {
        get { wizardData.archiveDir }
        set { wizardData.archiveDir = newValue }
    }

    var destinationDevice: DeviceInfo? { wizardData.destinationDevice }
    var destinationTrustState: TrustState { wizardData.destinationTrustState }
    var isWaitingForDestination: Bool {
        if case .connectDestination(let sub) = state { return sub.isWaiting }
        return false
    }

    var transferProgress: TransferProgress? { wizardData.transferProgress }
    var transferResult: TransferResult? { wizardData.transferResult }

    var appleIDAuthenticated: Bool { wizardData.appleIDAuthenticated }
    var isCheckingAppleID: Bool {
        if case .dependencyCheck(let sub) = state { return sub.isCheckingAppleID }
        return false
    }
    var isAuthenticatingAppleID: Bool {
        if case .dependencyCheck(let sub) = state { return sub.isAuthenticatingAppleID }
        return false
    }
    var appleIDLoginError: String? { wizardData.appleIDLoginError }
    var appleIDNeedsTwoFactor: Bool { wizardData.appleIDNeedsTwoFactor }
    var appleIDEmailForTwoFactor: String { wizardData.appleIDEmailForTwoFactor }

    var lastError: String? { wizardData.lastError }

    var selectedAppsCount: Int { wizardData.selectedBundleIDs.count }
    var canProceedFromSelectApps: Bool { !wizardData.selectedBundleIDs.isEmpty }
    var canProceedFromChooseAction: Bool { true }

    // MARK: - Step 1: Dependency Check

    func checkDependencies() async {
        wizardData.dependencyStatus = nil
        wizardData.lastError = nil
        let status = await service.checkDependencies()
        wizardData.dependencyStatus = status
        if case .ready = status {
            await checkAppleIDStatus()
            if wizardData.appleIDAuthenticated {
                state = .connectSource(ConnectDeviceSubstate())
            }
        }
    }

    func installDependencies() async {
        guard case .dependencyCheck(var sub) = state, !sub.isInstallingDependencies else { return }
        sub.isInstallingDependencies = true
        state = .dependencyCheck(sub)
        wizardData.installOutput = []
        wizardData.lastError = nil

        do {
            try await service.installDependencies { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.wizardData.installOutput.append(line)
                }
            }
            let status = await service.checkDependencies()
            wizardData.dependencyStatus = status
            if case .ready = status {
                await checkAppleIDStatus()
                if wizardData.appleIDAuthenticated {
                    state = .connectSource(ConnectDeviceSubstate())
                    return
                }
            }
        } catch {
            wizardData.lastError = error.localizedDescription
        }

        if case .dependencyCheck(var sub) = state {
            sub.isInstallingDependencies = false
            state = .dependencyCheck(sub)
        }
    }

    // MARK: - Apple ID Auth Helpers

    func checkAppleIDStatus() async {
        guard case .dependencyCheck(var sub) = state else { return }
        sub.isCheckingAppleID = true
        state = .dependencyCheck(sub)

        wizardData.appleIDAuthenticated = await service.checkAppleIDAuth()

        if case .dependencyCheck(var s) = state {
            s.isCheckingAppleID = false
            state = .dependencyCheck(s)
        }
    }

    func loginAppleID(email: String, password: String) async {
        await runAppleIDAuth { [weak self] in
            guard let self else { return }
            do {
                try await self.service.loginAppleID(email: email, password: password, authCode: nil)
                self.wizardData.appleIDAuthenticated = true
                self.wizardData.appleIDEmailForTwoFactor = ""
                self.state = .connectSource(ConnectDeviceSubstate())
            } catch iMobileDeviceError.twoFactorRequired {
                self.wizardData.appleIDNeedsTwoFactor = true
                self.wizardData.appleIDEmailForTwoFactor = email
            } catch {
                self.wizardData.appleIDLoginError = error.localizedDescription
            }
        }
    }

    func loginAppleIDWithTwoFactor(email: String, password: String, code: String) async {
        await runAppleIDAuth { [weak self] in
            guard let self else { return }
            do {
                try await self.service.loginAppleID(email: email, password: password, authCode: code)
                self.wizardData.appleIDAuthenticated = true
                self.wizardData.appleIDNeedsTwoFactor = false
                self.wizardData.appleIDEmailForTwoFactor = ""
                self.state = .connectSource(ConnectDeviceSubstate())
            } catch {
                self.wizardData.appleIDLoginError = error.localizedDescription
            }
        }
    }

    func cancelAppleIDLogin() {
        wizardData.appleIDNeedsTwoFactor = false
        wizardData.appleIDLoginError = nil
        wizardData.appleIDEmailForTwoFactor = ""
    }

    private func runAppleIDAuth(_ body: () async -> Void) async {
        guard case .dependencyCheck(var sub) = state else { return }
        sub.isAuthenticatingAppleID = true
        state = .dependencyCheck(sub)
        wizardData.appleIDLoginError = nil
        wizardData.appleIDNeedsTwoFactor = false

        await body()

        if case .dependencyCheck(var s) = state {
            s.isAuthenticatingAppleID = false
            state = .dependencyCheck(s)
        }
    }

    // MARK: - Step 2: Connect Source

    func startSourceDeviceObservation() {
        stopDeviceObservation()
        state = .connectSource(ConnectDeviceSubstate(isWaiting: true))
        deviceObservationTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.observeDevices(pollingInterval: 2.0) {
                if Task.isCancelled { return }
                self.handleDeviceEvent(event, role: .source)
                if self.wizardData.sourceDevice != nil, self.wizardData.sourceTrustState == .trusted {
                    break
                }
            }
            if Task.isCancelled { return }
            // Loop ended — clear the waiting flag and proceed.
            if case .connectSource = self.state {
                self.state = .connectSource(ConnectDeviceSubstate(isWaiting: false))
            }
            await self.loadSourceApps()
            if !self.wizardData.availableApps.isEmpty || self.wizardData.lastError != nil {
                self.state = .selectApps(SelectAppsSubstate())
            }
        }
    }

    func stopDeviceObservation() {
        deviceObservationTask?.cancel()
        deviceObservationTask = nil
    }

    // MARK: - Step 3: Select Apps

    func loadSourceApps() async {
        guard let udid = wizardData.sourceDevice?.udid else { return }
        state = .selectApps(SelectAppsSubstate(isLoadingApps: true))
        wizardData.lastError = nil
        do {
            wizardData.availableApps = try await service.listApps(udid: udid)
        } catch {
            wizardData.lastError = error.localizedDescription
        }
        state = .selectApps(SelectAppsSubstate(isLoadingApps: false))
    }

    func toggleAppSelection(_ bundleID: String) {
        if wizardData.selectedBundleIDs.contains(bundleID) {
            wizardData.selectedBundleIDs.remove(bundleID)
        } else {
            wizardData.selectedBundleIDs.insert(bundleID)
        }
    }

    func selectAllApps() {
        wizardData.selectedBundleIDs = Set(wizardData.availableApps.map(\.bundleID))
    }

    func deselectAllApps() {
        wizardData.selectedBundleIDs = []
    }

    // MARK: - Step 4: Choose Action

    func chooseArchiveOnly() {
        wizardData.archiveOnly = true
    }

    func chooseArchiveAndInstall() {
        wizardData.archiveOnly = false
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
            wizardData.archiveDir = panel.url
        }
    }

    func proceedFromChooseAction() {
        if wizardData.archiveOnly {
            state = .transferring
        } else {
            state = .connectDestination(ConnectDeviceSubstate())
        }
    }

    // MARK: - Step 5: Connect Destination

    func startDestinationDeviceObservation() {
        stopDeviceObservation()
        state = .connectDestination(ConnectDeviceSubstate(isWaiting: true))
        deviceObservationTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.service.observeDevices(pollingInterval: 2.0) {
                if Task.isCancelled { return }
                self.handleDeviceEvent(event, role: .destination)
                if self.wizardData.destinationDevice != nil,
                   self.wizardData.destinationTrustState == .trusted {
                    break
                }
            }
        }
    }

    // MARK: - Step 6: Transfer

    func startTransfer() {
        guard let sourceUDID = wizardData.sourceDevice?.udid else { return }

        let selectedApps = wizardData.availableApps.filter {
            wizardData.selectedBundleIDs.contains($0.bundleID)
        }
        guard !selectedApps.isEmpty else { return }

        let destUDID: String? = wizardData.archiveOnly ? nil : wizardData.destinationDevice?.udid
        let dir = wizardData.archiveDir ?? archiveService.archiveDirectory
        wizardData.transferProgress = nil
        wizardData.lastError = nil

        transferTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.service.transferApps(
                sourceUDID: sourceUDID,
                destinationUDID: destUDID,
                apps: selectedApps,
                archiveDir: dir,
                shouldInstall: !self.wizardData.archiveOnly
            )
            do {
                for try await progress in stream {
                    if Task.isCancelled { return }
                    self.wizardData.transferProgress = progress
                }
                self.buildTransferResult(from: selectedApps)
            } catch {
                if Task.isCancelled { return }
                self.wizardData.lastError = error.localizedDescription
                self.buildTransferResult(from: selectedApps)
            }
            if Task.isCancelled { return }
            self.state = .result
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
        state = .dependencyCheck(DependencyCheckSubstate())
        var fresh = iTransferWizardData()
        // Match the historical reset behaviour — `archiveOnly` defaults to
        // true so users land on "archive only" after a transfer completes
        // (sensible default for the most common follow-up scenario).
        fresh.archiveOnly = true
        wizardData = fresh
    }

    // MARK: - Private

    private enum DeviceRole { case source, destination }

    private func handleDeviceEvent(_ event: DeviceEvent, role: DeviceRole) {
        switch event {
        case .connected(let device):
            if role == .source, wizardData.sourceDevice == nil {
                wizardData.sourceDevice = device
                wizardData.sourceTrustState = .notTrusted
            } else if role == .destination, wizardData.destinationDevice == nil,
                      device.udid != wizardData.sourceDevice?.udid {
                wizardData.destinationDevice = device
                wizardData.destinationTrustState = .notTrusted
            }

        case .disconnected(let udid):
            if role == .source, wizardData.sourceDevice?.udid == udid {
                wizardData.sourceDevice = nil
                wizardData.sourceTrustState = .notTrusted
            } else if role == .destination, wizardData.destinationDevice?.udid == udid {
                wizardData.destinationDevice = nil
                wizardData.destinationTrustState = .notTrusted
            }

        case .trustStateChanged(let udid, let trustState):
            if wizardData.sourceDevice?.udid == udid {
                wizardData.sourceTrustState = trustState
                if trustState == .trusted, case .connectSource = state {
                    Task { [weak self] in
                        guard let self else { return }
                        if let updated = try? await self.service.listDevices()
                            .first(where: { $0.udid == udid }) {
                            if Task.isCancelled { return }
                            self.wizardData.sourceDevice = updated
                        }
                    }
                }
            } else if wizardData.destinationDevice?.udid == udid {
                wizardData.destinationTrustState = trustState
                if trustState == .trusted, case .connectDestination = state {
                    Task { [weak self] in
                        guard let self else { return }
                        if let updated = try? await self.service.listDevices()
                            .first(where: { $0.udid == udid }) {
                            if Task.isCancelled { return }
                            self.wizardData.destinationDevice = updated
                        }
                        if Task.isCancelled { return }
                        self.state = .transferring
                    }
                }
            }

        case .error:
            break
        }
    }

    private func buildTransferResult(from apps: [AppInfo]) {
        guard let progress = wizardData.transferProgress else {
            wizardData.transferResult = TransferResult(items: apps.map {
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
        wizardData.transferResult = TransferResult(items: results)
    }
}
