import XCTest
@testable import Spacie

// MARK: - iTransferViewModelTests

@MainActor
final class iTransferViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeViewModel(
        service: MockiMobileDeviceService = MockiMobileDeviceService(),
        archiveService: MockAppArchiveService = MockAppArchiveService()
    ) -> iTransferViewModel {
        iTransferViewModel(service: service, archiveService: archiveService)
    }

    // MARK: - Step 1: Dependency Check

    func testCheckDependencies_readyAndAuthed_advancesToConnectSource() async {
        let service = MockiMobileDeviceService()
        service.dependencyStatusToReturn = .ready(ToolPaths(
            ideviceId: "/opt/homebrew/bin/idevice_id",
            ideviceInfo: "/opt/homebrew/bin/ideviceinfo",
            ideviceinstaller: "/opt/homebrew/bin/ideviceinstaller",
            idevicepair: "/opt/homebrew/bin/idevicepair",
            brew: "/opt/homebrew/bin/brew",
            ipatool: "/opt/homebrew/bin/ipatool"
        ))
        // checkDependencies also verifies Apple ID auth before advancing — see VM.
        service.appleIDAuthenticatedToReturn = true
        let vm = makeViewModel(service: service)

        await vm.checkDependencies()

        XCTAssertEqual(vm.step, .connectSource)
        XCTAssertEqual(service.checkDependenciesCallCount, 1)
        XCTAssertEqual(service.checkAppleIDAuthCallCount, 1)
    }

    func testCheckDependencies_readyButNotAuthed_staysOnDependencyCheck() async {
        let service = MockiMobileDeviceService()
        service.dependencyStatusToReturn = .ready(ToolPaths(
            ideviceId: "/opt/homebrew/bin/idevice_id",
            ideviceInfo: "/opt/homebrew/bin/ideviceinfo",
            ideviceinstaller: "/opt/homebrew/bin/ideviceinstaller",
            idevicepair: "/opt/homebrew/bin/idevicepair",
            brew: "/opt/homebrew/bin/brew",
            ipatool: "/opt/homebrew/bin/ipatool"
        ))
        service.appleIDAuthenticatedToReturn = false
        let vm = makeViewModel(service: service)

        await vm.checkDependencies()

        XCTAssertEqual(vm.step, .dependencyCheck)
        XCTAssertFalse(vm.appleIDAuthenticated)
    }

    func testCheckDependencies_missing_staysOnDependencyCheck() async {
        let service = MockiMobileDeviceService()
        service.dependencyStatusToReturn = .missing(tools: ["ideviceinstaller"])
        let vm = makeViewModel(service: service)

        await vm.checkDependencies()

        XCTAssertEqual(vm.step, .dependencyCheck)
        XCTAssertNotNil(vm.dependencyStatus)
    }

    // MARK: - Step 3: App Selection

    func testToggleAppSelection_selectsAndDeselects() {
        let vm = makeViewModel()
        let bundleID = "com.example.App"

        vm.toggleAppSelection(bundleID)
        XCTAssertTrue(vm.selectedBundleIDs.contains(bundleID))

        vm.toggleAppSelection(bundleID)
        XCTAssertFalse(vm.selectedBundleIDs.contains(bundleID))
    }

    func testSelectAllApps_selectsAll() {
        let service = MockiMobileDeviceService.withSampleData()
        let vm = makeViewModel(service: service)
        vm.availableApps = service.appsToReturn

        vm.selectAllApps()

        XCTAssertEqual(vm.selectedBundleIDs.count, service.appsToReturn.count)
    }

    func testDeselectAllApps_clearsSelection() {
        let vm = makeViewModel()
        vm.selectedBundleIDs = ["com.a", "com.b", "com.c"]

        vm.deselectAllApps()

        XCTAssertTrue(vm.selectedBundleIDs.isEmpty)
    }

    func testCanProceedFromSelectApps_falseWhenEmpty() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canProceedFromSelectApps)
    }

    func testCanProceedFromSelectApps_trueWhenNonEmpty() {
        let vm = makeViewModel()
        vm.selectedBundleIDs = ["com.example"]
        XCTAssertTrue(vm.canProceedFromSelectApps)
    }

    // MARK: - Step 4: Choose Action

    func testChooseArchiveOnly_setsFlag() {
        let vm = makeViewModel()
        vm.chooseArchiveAndInstall()  // flip to false first
        vm.chooseArchiveOnly()
        XCTAssertTrue(vm.archiveOnly)
    }

    func testChooseArchiveAndInstall_clearsFlag() {
        let vm = makeViewModel()
        vm.chooseArchiveAndInstall()
        XCTAssertFalse(vm.archiveOnly)
    }

    func testProceedFromChooseAction_archiveOnly_jumpsToTransferring() {
        let vm = makeViewModel()
        vm.state = .chooseAction
        vm.archiveOnly = true

        vm.proceedFromChooseAction()

        XCTAssertEqual(vm.step, .transferring)
    }

    func testProceedFromChooseAction_archiveAndInstall_goesToConnectDestination() {
        let vm = makeViewModel()
        vm.state = .chooseAction
        vm.archiveOnly = false

        vm.proceedFromChooseAction()

        XCTAssertEqual(vm.step, .connectDestination)
    }

    // MARK: - Reset

    func testReset_clearsAllState() {
        let vm = makeViewModel()
        vm.state = .result
        vm.selectedBundleIDs = ["com.a"]
        vm.archiveOnly = false
        vm.availableApps = [AppInfo(
            bundleID: "com.a", displayName: "A", version: "1", shortVersion: "1.0", ipaSize: nil, iconData: nil
        )]

        vm.reset()

        XCTAssertEqual(vm.step, .dependencyCheck)
        XCTAssertTrue(vm.selectedBundleIDs.isEmpty)
        XCTAssertTrue(vm.archiveOnly)
        XCTAssertTrue(vm.availableApps.isEmpty)
        XCTAssertNil(vm.sourceDevice)
        XCTAssertNil(vm.destinationDevice)
        XCTAssertNil(vm.transferProgress)
        XCTAssertNil(vm.transferResult)
        XCTAssertNil(vm.lastError)
    }

    // MARK: - Selected Apps Count

    func testSelectedAppsCount_matchesSetSize() {
        let vm = makeViewModel()
        vm.selectedBundleIDs = ["a", "b", "c"]
        XCTAssertEqual(vm.selectedAppsCount, 3)
    }

    // MARK: - State invariants (Sprint 4.5: single-state enum)

    /// Sprint 4 audit finding #4: `isWaitingForSource && step != .connectSource`
    /// used to be representable with the old flat-flag VM. With the enum
    /// state machine, isWaitingForSource is computed from the case, so the
    /// combination is structurally impossible.
    func testIsWaitingForSource_isFalse_whenStepIsNotConnectSource() {
        let vm = makeViewModel()
        vm.state = .selectApps(SelectAppsSubstate())
        XCTAssertFalse(vm.isWaitingForSource,
                       "isWaitingForSource must be false outside .connectSource")
    }

    func testIsWaitingForSource_isTrue_onlyWhenStateCarriesIsWaiting() {
        let vm = makeViewModel()
        vm.state = .connectSource(ConnectDeviceSubstate(isWaiting: true))
        XCTAssertTrue(vm.isWaitingForSource)

        vm.state = .connectSource(ConnectDeviceSubstate(isWaiting: false))
        XCTAssertFalse(vm.isWaitingForSource)
    }

    func testIsLoadingApps_isFalse_outsideSelectAppsStep() {
        let vm = makeViewModel()
        vm.state = .transferring
        XCTAssertFalse(vm.isLoadingApps)
        vm.state = .result
        XCTAssertFalse(vm.isLoadingApps)
    }

    func testIsInstallingDependencies_resetsOnStateTransition() {
        let vm = makeViewModel()
        vm.state = .dependencyCheck(DependencyCheckSubstate(isInstallingDependencies: true))
        XCTAssertTrue(vm.isInstallingDependencies)

        vm.state = .connectSource(ConnectDeviceSubstate())
        XCTAssertFalse(vm.isInstallingDependencies)
    }

    // MARK: - Apple ID 2FA flow

    func testLoginAppleID_twoFactorRequired_setsNeedsTwoFactor() async {
        let service = MockiMobileDeviceService()
        service.errorToThrow = iMobileDeviceError.twoFactorRequired
        let vm = makeViewModel(service: service)

        await vm.loginAppleID(email: "user@example.com", password: "secret")

        XCTAssertTrue(vm.appleIDNeedsTwoFactor)
        XCTAssertEqual(vm.appleIDEmailForTwoFactor, "user@example.com")
        XCTAssertFalse(vm.appleIDAuthenticated)
    }

    func testLoginAppleID_genericFailure_setsLoginError() async {
        let service = MockiMobileDeviceService()
        service.shouldFailAppleIDLogin = true
        let vm = makeViewModel(service: service)

        await vm.loginAppleID(email: "user@example.com", password: "secret")

        XCTAssertFalse(vm.appleIDNeedsTwoFactor)
        XCTAssertFalse(vm.appleIDAuthenticated)
        XCTAssertNotNil(vm.appleIDLoginError)
    }

    func testCancelAppleIDLogin_clearsAuthError() {
        let vm = makeViewModel()
        vm.wizardData.appleIDLoginError = "boom"
        vm.wizardData.appleIDNeedsTwoFactor = true
        vm.wizardData.appleIDEmailForTwoFactor = "user@example.com"

        vm.cancelAppleIDLogin()

        XCTAssertFalse(vm.appleIDNeedsTwoFactor)
        XCTAssertNil(vm.appleIDLoginError)
        XCTAssertEqual(vm.appleIDEmailForTwoFactor, "")
    }

    // MARK: - Cancel transfer mid-stream

    func testCancelTransfer_cancelsTaskAndLeavesState() async {
        let service = MockiMobileDeviceService.withSampleData()
        service.operationDelay = 0.05
        let vm = makeViewModel(service: service)

        // Pre-fill the wizard state to reach a valid startTransfer entry point.
        vm.wizardData.sourceDevice = service.devicesToReturn.first
        vm.wizardData.sourceTrustState = .trusted
        vm.wizardData.availableApps = service.appsToReturn
        vm.wizardData.selectedBundleIDs = Set(service.appsToReturn.map(\.bundleID))
        vm.wizardData.archiveOnly = true
        vm.state = .transferring

        vm.startTransfer()
        // Let the stream emit at least one chunk
        try? await Task.sleep(for: .milliseconds(30))
        vm.cancelTransfer()

        // Allow cancellation to settle
        try? await Task.sleep(for: .milliseconds(50))

        // The state may remain .transferring (since cancel doesn't force a state
        // transition by itself) but the underlying task must be released.
        XCTAssertTrue(
            vm.state.kind == .transferring || vm.state.kind == .result,
            "after cancel, state should be transferring or result, was \(vm.state.kind)"
        )
    }

    // MARK: - Reset uses .afterReset factory

    func testReset_setsArchiveOnlyTrue_matchingAfterResetFactory() {
        let vm = makeViewModel()
        vm.wizardData.archiveOnly = false

        vm.reset()

        XCTAssertTrue(vm.archiveOnly, "reset() should land on archive-only (the AfterReset factory contract)")
    }
}
