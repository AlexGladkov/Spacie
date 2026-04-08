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

    func testCheckDependencies_ready_advancesToConnectSource() async {
        let service = MockiMobileDeviceService()
        service.dependencyStatusToReturn = .ready(ToolPaths(
            ideviceId: "/opt/homebrew/bin/idevice_id",
            ideviceInfo: "/opt/homebrew/bin/ideviceinfo",
            ideviceinstaller: "/opt/homebrew/bin/ideviceinstaller",
            idevicepair: "/opt/homebrew/bin/idevicepair",
            brew: "/opt/homebrew/bin/brew"
        ))
        let vm = makeViewModel(service: service)

        await vm.checkDependencies()

        XCTAssertEqual(vm.step, .connectSource)
        XCTAssertEqual(service.checkDependenciesCallCount, 1)
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
        vm.step = .chooseAction
        vm.archiveOnly = true

        vm.proceedFromChooseAction()

        XCTAssertEqual(vm.step, .transferring)
    }

    func testProceedFromChooseAction_archiveAndInstall_goesToConnectDestination() {
        let vm = makeViewModel()
        vm.step = .chooseAction
        vm.archiveOnly = false

        vm.proceedFromChooseAction()

        XCTAssertEqual(vm.step, .connectDestination)
    }

    // MARK: - Reset

    func testReset_clearsAllState() {
        let vm = makeViewModel()
        vm.step = .result
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
}
