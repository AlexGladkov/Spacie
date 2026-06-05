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
    /// Task spawned when a device transitions to `.trusted` to re-fetch its
    /// metadata. Tracked (instead of fire-and-forget) so successive
    /// trust-state events cancel the previous fetch and never mutate
    /// `wizardData` after the user has navigated away.
    @ObservationIgnored
    private var trustUpdateTask: Task<Void, Never>?
    /// Tracks the in-flight checkDependencies call. Rapid sheet
    /// dismiss/reopen used to leak the previous KMP continuation by spawning
    /// a second concurrent `withCheckedContinuation` against
    /// `kmpService.checkDependencies` — the bridge fires its completion
    /// exactly once, so the loser was suspended forever.
    @ObservationIgnored
    private var dependencyCheckTask: Task<Void, Never>?
    /// Same role as `installDependenciesGeneration` — detects when `reset()`
    /// (or a subsequent checkDependencies call) invalidated this run.
    @ObservationIgnored
    private var dependencyCheckGeneration: Int = 0
    /// Tracks the multi-minute `brew install` invocation. Without this, a
    /// fire-and-forget `Task { await viewModel.installDependencies() }` (see
    /// `DependencyCheckStep`) kept mutating `wizardData` on a torn-down
    /// view-model when the sheet was dismissed mid-install.
    @ObservationIgnored
    private var installDependenciesTask: Task<Void, Error>?
    /// Generation counter incremented on each `installDependencies` entry.
    /// Used by the function body to detect that `reset()` (or a subsequent
    /// install call) invalidated this run, since `Task` is a struct and
    /// can't be compared by reference.
    @ObservationIgnored
    private var installDependenciesGeneration: Int = 0
    /// Tracks the in-flight Apple-ID sign-in. View buttons can fire the call
    /// with a lightweight wrapper `Task` and rely on this handle to be
    /// cancelled from `deinit` — preventing an orphan auth result from
    /// resurrecting a dismissed wizard.
    @ObservationIgnored
    private var appleIDLoginTask: Task<Void, Never>?
    /// True while a transfer is actively running. Cleared once the transfer
    /// task body finishes (any path: success, failure, or cancel). Used by
    /// `startTransfer()` to suppress re-entry — checking `transferTask.isCancelled`
    /// instead conflated "completed" with "in-flight" and let a duplicate
    /// `.transferring` transition relaunch the wizard.
    // Regular MainActor-isolated stored property — `isolated deinit`
    // (Swift 6.1+) gives the deinit MainActor isolation, so it can
    // touch this without the `nonisolated(unsafe)` escape.
    @ObservationIgnored
    private var isTransferInFlight: Bool = false

    // MARK: - Init

    init(
        service: any iMobileDeviceProtocol = SharedDeviceServices.device,
        archiveService: any AppArchiveProtocol = SharedDeviceServices.archive
    ) {
        self.service = service
        self.archiveService = archiveService
    }

    isolated deinit {
        // Swift 6.1 isolated deinit: runs synchronously on MainActor so we
        // can access MainActor-isolated stored properties (like
        // `isTransferInFlight`) without `nonisolated(unsafe)` escapes.
        deviceObservationTask?.cancel()
        transferTask?.cancel()
        // Reset the in-flight flag synchronously alongside the cancel
        // (mirroring cancelTransfer's contract). Without this, a delayed
        // ARC release of the VM would leave the flag pinned and the next
        // VM instance — if one ever reuses this storage in tests or
        // previews — would silently no-op startTransfer.
        isTransferInFlight = false
        trustUpdateTask?.cancel()
        dependencyCheckTask?.cancel()
        installDependenciesTask?.cancel()
        appleIDLoginTask?.cancel()
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
        // De-duplicate via generation counter (same pattern as
        // installDependencies). Bump BEFORE storing the task handle so a
        // `reset()` racing between handle-store and bump cannot fool
        // `stillOwned()` into returning true on an invalidated run.
        dependencyCheckGeneration &+= 1
        let myGeneration = dependencyCheckGeneration

        let previous = dependencyCheckTask
        previous?.cancel()
        _ = await previous?.value

        func stillOwned() -> Bool {
            dependencyCheckGeneration == myGeneration
        }

        let task = Task { [weak self] in
            guard let self else { return }
            guard stillOwned() else { return }
            self.wizardData.dependencyStatus = nil
            self.wizardData.lastError = nil
            let status = await self.service.checkDependencies()
            if Task.isCancelled || !stillOwned() { return }
            self.wizardData.dependencyStatus = status
            if case .ready = status {
                await self.checkAppleIDStatus()
                if Task.isCancelled || !stillOwned() { return }
                if self.wizardData.appleIDAuthenticated {
                    self.state = .connectSource(ConnectDeviceSubstate())
                }
            }
        }
        dependencyCheckTask = task
        _ = await task.value
    }

    func installDependencies() async {
        guard case .dependencyCheck(var sub) = state, !sub.isInstallingDependencies else { return }
        // Defence in depth: if a cancelled dependency check left a
        // `.missing(tools: [])` shape in flight, refuse to run `brew install`
        // with an empty package list. Re-run the check instead.
        if case .missing(let tools) = wizardData.dependencyStatus, tools.isEmpty {
            await checkDependencies()
            return
        }
        sub.isInstallingDependencies = true
        state = .dependencyCheck(sub)
        wizardData.installOutput = []
        wizardData.lastError = nil

        // Use a single AsyncStream to funnel stdout lines from the off-actor KMP
        // callback to this MainActor for-loop, instead of spawning one Task per
        // line (which produced N unbounded fire-and-forget tasks per install).
        let (lineStream, lineContinuation) = AsyncStream<String>.makeStream()

        // Capture + cancel + AWAIT the previous KMP install before starting
        // a new one. Two concurrent withCheckedContinuation calls against
        // the single-completion KMP bridge would suspend the loser forever.
        let previousInstall = installDependenciesTask
        previousInstall?.cancel()
        _ = try? await previousInstall?.value

        // Order matters: bump the generation and capture `myGeneration`
        // BEFORE storing the handle. If `reset()` fires after we store the
        // handle but before we bump, it would race the bump and `myGeneration`
        // could equal the post-reset value, fooling `stillOwned()` into
        // returning `true` on an invalidated run.
        installDependenciesGeneration &+= 1
        let myGeneration = installDependenciesGeneration
        let installTask = Task { [service] in
            defer { lineContinuation.finish() }
            try await service.installDependencies { line in
                lineContinuation.yield(line)
            }
        }
        installDependenciesTask = installTask

        // From here on, every Task.isCancelled check refers to the install
        // task scope, since `for await … in lineStream` and the awaited
        // `installTask.value` propagate cancellation from the enclosing
        // caller through this function's Task context.
        for await line in lineStream {
            if Task.isCancelled { break }
            wizardData.installOutput.append(line)
        }

        // Generation check: if `reset()` (or another install call)
        // incremented `installDependenciesGeneration` or cleared the
        // task while we were awaiting, that means the outer flow
        // logically cancelled this run and we must NOT keep mutating
        // wizardData — the outer View Task wrapping this call has no
        // direct cancellation visible to us, so we observe ownership
        // through this monotonically-increasing generation marker.
        func stillOwned() -> Bool {
            installDependenciesTask != nil
                && installDependenciesGeneration == myGeneration
        }

        // Defer ensures the spinner is cleared on EVERY return path,
        // including the .ready-but-not-auth fallthrough that previously
        // left isInstallingDependencies pinned forever when a second
        // installDependencies call raced in during checkAppleIDStatus.
        defer {
            if stillOwned() {
                installDependenciesTask = nil
                if case .dependencyCheck(var sub) = state {
                    sub.isInstallingDependencies = false
                    state = .dependencyCheck(sub)
                }
            }
        }

        do {
            _ = try await installTask.value
            if !stillOwned() { return }
            let status = await service.checkDependencies()
            if !stillOwned() { return }
            wizardData.dependencyStatus = status
            if case .ready = status {
                await checkAppleIDStatus()
                if !stillOwned() { return }
                if wizardData.appleIDAuthenticated {
                    state = .connectSource(ConnectDeviceSubstate())
                    return
                }
            }
        } catch is CancellationError {
            // Cancellation is benign — don't surface as user-facing error.
            // Return early so the post-catch fall-through doesn't mutate
            // wizardData on a reset state.
            return
        } catch {
            if stillOwned() {
                wizardData.lastError = error.localizedDescription
            } else {
                return
            }
        }

        // Cleanup happens in the defer block above.
    }

    // MARK: - Apple ID Auth Helpers

    func checkAppleIDStatus() async {
        guard case .dependencyCheck(var sub) = state else { return }
        sub.isCheckingAppleID = true
        state = .dependencyCheck(sub)

        // Ensure isCheckingAppleID is always cleared, even on the post-await
        // early-return paths. Previously a state transition during the await
        // left the spinner pinned on permanently if the user came back to
        // the dependency-check step.
        defer {
            if case .dependencyCheck(var s) = state {
                s.isCheckingAppleID = false
                state = .dependencyCheck(s)
            }
        }

        let authed = await service.checkAppleIDAuth()
        if Task.isCancelled { return }
        guard case .dependencyCheck = state else { return }
        wizardData.appleIDAuthenticated = authed
    }

    func loginAppleID(email: String, password: String) async {
        // Track + await previous so concurrent KMP loginAppleID
        // continuations cannot accumulate. The bridge fires its single
        // completion exactly once — without awaiting the previous task,
        // a double-tap "Sign in" leaves the losing continuation
        // permanently suspended.
        let previous = appleIDLoginTask
        previous?.cancel()
        _ = await previous?.value
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAppleIDAuth { [weak self] in
                guard let self else { return }
                do {
                    try await self.service.loginAppleID(email: email, password: password, authCode: nil)
                    if Task.isCancelled { return }
                    self.wizardData.appleIDAuthenticated = true
                    self.wizardData.appleIDEmailForTwoFactor = ""
                    self.state = .connectSource(ConnectDeviceSubstate())
                } catch iMobileDeviceError.twoFactorRequired {
                    if Task.isCancelled { return }
                    self.wizardData.appleIDNeedsTwoFactor = true
                    self.wizardData.appleIDEmailForTwoFactor = email
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.wizardData.appleIDLoginError = error.localizedDescription
                }
            }
        }
        appleIDLoginTask = task
        _ = await task.value
    }

    func loginAppleIDWithTwoFactor(email: String, password: String, code: String) async {
        // Mirror loginAppleID's awaited cancel — see comment above.
        let previous = appleIDLoginTask
        previous?.cancel()
        _ = await previous?.value
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAppleIDAuth { [weak self] in
                guard let self else { return }
                do {
                    try await self.service.loginAppleID(email: email, password: password, authCode: code)
                    if Task.isCancelled { return }
                    self.wizardData.appleIDAuthenticated = true
                    self.wizardData.appleIDNeedsTwoFactor = false
                    self.wizardData.appleIDEmailForTwoFactor = ""
                    self.state = .connectSource(ConnectDeviceSubstate())
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.wizardData.appleIDLoginError = error.localizedDescription
                }
            }
        }
        appleIDLoginTask = task
        _ = await task.value
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
                // The differ stays silent for the FIRST observation of a
                // device — so a device that connects already-trusted never
                // fires `.trustStateChanged` and this loop would otherwise
                // spin forever. Proactively re-validate when we just saw a
                // .connected event so the wizard can advance.
                if case .connected = event,
                   let udid = self.wizardData.sourceDevice?.udid,
                   self.wizardData.sourceTrustState != .trusted {
                    // Local var `trust` (not `state`) — avoid shadowing the
                    // view-model's `state` property, which would silently
                    // route reads/writes to the local during the rest of
                    // this iteration.
                    let trust = await self.service.validateTrust(udid: udid)
                    // Re-check cancellation AFTER the await: stopDeviceObservation()
                    // can fire while validateTrust is suspended and we must
                    // not write to wizardData on a torn-down view-model.
                    if Task.isCancelled { return }
                    self.wizardData.sourceTrustState = trust
                }
                if self.wizardData.sourceDevice != nil, self.wizardData.sourceTrustState == .trusted {
                    break
                }
            }
            if Task.isCancelled { return }
            // Loop ended — clear the waiting flag and proceed.
            // Guard the whole tail on `state == .connectSource`: if the user
            // navigated away (Reset/Back) while we were waiting on a device,
            // we must not re-enter loadSourceApps() and then transition to
            // .selectApps over their new screen.
            guard case .connectSource = self.state else { return }
            self.state = .connectSource(ConnectDeviceSubstate(isWaiting: false))
            await self.loadSourceApps()
            guard case .connectSource = self.state else { return }
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
        } catch is CancellationError {
            // Cancellation isn't a user-visible failure.
            return
        } catch {
            if Task.isCancelled { return }
            wizardData.lastError = error.localizedDescription
        }
        // Re-check cancellation BEFORE flipping to the loaded state — otherwise
        // a stopDeviceObservation() firing during listApps would leave the
        // wizard parked on .selectApps with a stale "operation cancelled"
        // message instead of returning to the prior step cleanly.
        if Task.isCancelled { return }
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

    /// View-facing transition out of the Select Apps step. Routed through
    /// the VM (not via direct `viewModel.state =` mutation in the View) so
    /// any future guards / side-effects attached to this transition are
    /// enforced consistently with the other step transitions.
    func proceedFromSelectApps() {
        guard case .selectApps = state else { return }
        guard canProceedFromSelectApps else { return }
        state = .chooseAction
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
        // Pre-flight archiveDir check applies to BOTH archive-only and
        // install paths — KMP's transferApps always writes archive entries
        // when `archiveDir != nil`, even in install mode. Without this guard
        // the install path also failed mid-transfer on unwritable volumes.
        let dir = wizardData.archiveDir ?? archiveService.archiveDirectory
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true
            )
        } catch {
            wizardData.lastError =
                "Archive folder is not writable (\(error.localizedDescription)). Choose another location."
            return
        }
        // Defence-in-depth: after lazy-create, verify the path is actually
        // writable (read-only mount can let mkdir succeed via cache but
        // reject subsequent writes).
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            wizardData.lastError = "Archive folder is read-only. Choose another location."
            return
        }
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
                // Mirror the source-loop fix: probe trust on .connected so
                // an already-trusted destination unblocks the wizard.
                if case .connected = event,
                   let udid = self.wizardData.destinationDevice?.udid,
                   self.wizardData.destinationTrustState != .trusted {
                    // Renamed (was `state`) — see source-loop comment.
                    let trust = await self.service.validateTrust(udid: udid)
                    if Task.isCancelled { return }
                    self.wizardData.destinationTrustState = trust
                }
                if self.wizardData.destinationDevice != nil,
                   self.wizardData.destinationTrustState == .trusted {
                    break
                }
            }
            if Task.isCancelled { return }
            // Drive the wizard forward AFTER the loop breaks. Previously the
            // only path to `.transferring` was via the trustStateChanged
            // event in `handleDeviceEvent`; if the device showed up already
            // trusted (or the trust event coincided with the loop break),
            // the wizard hung on `connectDestination` forever.
            guard case .connectDestination = self.state else { return }
            if self.wizardData.destinationDevice != nil,
               self.wizardData.destinationTrustState == .trusted {
                self.state = .transferring
            } else {
                self.state = .connectDestination(ConnectDeviceSubstate(isWaiting: false))
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

        // Idempotency guard. Two independent code paths can transition us to
        // `.transferring` (the destination observation post-loop fallthrough
        // AND `spawnTrustUpdate(role: .destination)`); SwiftUI then fires
        // TransferringStepView.task twice. Without this guard the second
        // entry cancelled the first transfer mid-flight, wiped progress,
        // and silently restarted — losing all work in flight.
        //
        // `Task.isCancelled` is true even for completed tasks; we want to
        // suppress re-entry only while the transfer is genuinely running.
        // Use a dedicated isInFlight flag instead of inspecting the handle.
        if isTransferInFlight {
            return
        }
        isTransferInFlight = true

        let destUDID: String? = wizardData.archiveOnly ? nil : wizardData.destinationDevice?.udid
        // Archive-dir semantics:
        //  - archiveOnly = true  → always archive (use user pick or default)
        //  - archiveOnly = false → archive only if user explicitly picked a
        //    directory; nil means "install only, skip archive". Previously
        //    `dir = archiveDir ?? default` silently archived every install,
        //    which the user never consented to.
        let dir: URL? = wizardData.archiveOnly
            ? (wizardData.archiveDir ?? archiveService.archiveDirectory)
            : wizardData.archiveDir
        wizardData.transferProgress = nil
        wizardData.lastError = nil

        // Cancel any (finished/cancelled) previous handle to release it
        // cleanly. We do NOT await here because the caller (a SwiftUI
        // .task) needs to return promptly; isTransferInFlight above
        // already guards against duplicate live transfers, so this only
        // happens for prior tasks that have themselves finished.
        transferTask?.cancel()
        // Make the state transition explicit too — handleDeviceEvent and the
        // destination-loop fallback drive us here, but a direct startTransfer()
        // (archive-only path from `proceedFromChooseAction`) needs to ensure
        // the wizard reflects the active phase.
        state = .transferring

        transferTask = Task { [weak self] in
            guard let self else { return }
            // Confirm we still own the flag at task entry — if the previous
            // cancel + new startTransfer race left a stale handle that
            // never ran its tail, the flag could otherwise stick true with
            // no live task. Re-assert here so the tail's natural-completion
            // clear runs exactly once for THIS run.
            if Task.isCancelled {
                self.isTransferInFlight = false
                return
            }
            let stream = self.service.transferApps(
                sourceUDID: sourceUDID,
                destinationUDID: destUDID,
                apps: selectedApps,
                archiveDir: dir,
                shouldInstall: !self.wizardData.archiveOnly
            )
            do {
                for try await progress in stream {
                    if Task.isCancelled { break }
                    // Drop progress events that arrive after the user
                    // navigated away (Reset / Back) — otherwise we
                    // mutate transferProgress on a logically-dismissed
                    // wizard, which Observable then surfaces if the user
                    // re-enters the transferring step.
                    guard case .transferring = self.state else { break }
                    self.wizardData.transferProgress = progress
                }
            } catch is CancellationError {
                // Benign: handled by buildTransferResult below.
            } catch {
                if !Task.isCancelled {
                    self.wizardData.lastError = error.localizedDescription
                }
            }
            // Only clear isTransferInFlight from the tail when the task
            // ran to natural completion. `cancelTransfer()` clears it
            // synchronously; if the tail also cleared it here, a fresh
            // `startTransfer()` started between cancel and the late tail
            // would see the flag freshly cleared by the dead task and
            // skip its own re-entry protection.
            if Task.isCancelled { return }
            guard case .transferring = self.state else { return }
            self.buildTransferResult(from: selectedApps)
            self.state = .result
            self.isTransferInFlight = false
        }
    }

    func cancelTransfer() {
        let apps = wizardData.availableApps.filter {
            wizardData.selectedBundleIDs.contains($0.bundleID)
        }
        transferTask?.cancel()
        transferTask = nil
        // Clear the in-flight flag synchronously (see deinit-race comment).
        isTransferInFlight = false
        // Drive the wizard out of `.transferring` HERE — the task tail
        // returns early on `Task.isCancelled` and would otherwise leave
        // the user permanently stuck on the transfer screen. This used
        // to be done from the View ("viewModel.state = .result") but
        // that path was removed in iter6 to prevent a double-write race;
        // now the VM owns the cancel-to-result transition exclusively.
        guard case .transferring = state else { return }
        buildTransferResult(from: apps)
        state = .result
    }

    // MARK: - General

    /// Comprehensive task teardown invoked from the host view's
    /// `.onDisappear` AND from the toolbar Back button (NavigationStack pop
    /// is not guaranteed to fire `.onDisappear`).
    ///
    /// Idempotent: a second call after the first observes nil task handles
    /// and `state == .result` (cancelTransfer's transition), so all guards
    /// short-circuit cleanly. Safe to invoke multiple times.
    func teardownForDismiss() {
        stopDeviceObservation()
        cancelTransfer()
        installDependenciesTask?.cancel()
        installDependenciesTask = nil
        installDependenciesGeneration &+= 1
        appleIDLoginTask?.cancel()
        appleIDLoginTask = nil
        dependencyCheckTask?.cancel()
        dependencyCheckTask = nil
        trustUpdateTask?.cancel()
        trustUpdateTask = nil
    }

    func reset() {
        cancelTransfer()
        stopDeviceObservation()
        // Also tear down auth + install tasks so a still-streaming brew
        // install can't overwrite the freshly-reset wizardData after
        // "Transfer More" or sheet dismiss.
        installDependenciesTask?.cancel()
        installDependenciesTask = nil
        // Bump the generation so any installDependencies() body still
        // suspended on a KMP await observes that it no longer owns the
        // wizardData and returns without mutating freshly-reset state.
        installDependenciesGeneration &+= 1
        // Same defence for checkDependencies — a still-awaiting prior
        // run must not resurrect the dependencyStatus after reset.
        dependencyCheckGeneration &+= 1
        dependencyCheckTask?.cancel()
        dependencyCheckTask = nil
        appleIDLoginTask?.cancel()
        appleIDLoginTask = nil
        state = .dependencyCheck(DependencyCheckSubstate())
        wizardData = .afterReset()
        // Re-fire dependency check. Wrap through `dependencyCheckTask` so
        // the call is tracked and cancellable like every other awaited
        // dependency-check path; without this, a rapid "Transfer More" +
        // dismiss could leave the wizard parked with a stale nil status.
        Task { [weak self] in
            await self?.checkDependencies()
        }
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
                    spawnTrustUpdate(udid: udid, role: .source)
                }
            } else if wizardData.destinationDevice?.udid == udid {
                wizardData.destinationTrustState = trustState
                if trustState == .trusted, case .connectDestination = state {
                    spawnTrustUpdate(udid: udid, role: .destination)
                }
            }

        case .error:
            break
        }
    }

    /// Replaces any in-flight trust-update task with a fresh one that re-fetches
    /// device metadata for `udid` and updates the wizard data — but only if the
    /// user is still on the matching step. Guards against the previous
    /// fire-and-forget pattern where successive trust events spawned overlapping
    /// tasks and mutated state after navigation away.
    private func spawnTrustUpdate(udid: String, role: DeviceRole) {
        trustUpdateTask?.cancel()
        trustUpdateTask = Task { [weak self] in
            guard let self else { return }
            let updated = try? await self.service.listDevices()
                .first(where: { $0.udid == udid })
            if Task.isCancelled { return }
            switch role {
            case .source:
                guard case .connectSource = self.state else { return }
                if let updated { self.wizardData.sourceDevice = updated }
            case .destination:
                // Only refresh the cached DeviceInfo here. The state
                // transition to `.transferring` is owned by
                // `startDestinationDeviceObservation`'s post-loop
                // fallthrough — having two independent paths advance the
                // state caused them to race the `guard case .connectDestination`
                // check and sometimes BOTH bail out, leaving the wizard
                // hung on `.connectDestination` forever.
                guard case .connectDestination = self.state else { return }
                if let updated {
                    self.wizardData.destinationDevice = updated
                }
            }
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
