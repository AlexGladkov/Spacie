import XCTest
@testable import Spacie

// MARK: - InstallFromArchiveViewModelTests

@MainActor
final class InstallFromArchiveViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeApp(bundleID: String = "com.test.App") -> ArchivedApp {
        let url = URL(fileURLWithPath: "/tmp/\(bundleID).ipa")
        return ArchivedApp(
            id: bundleID,
            metadata: ArchivedAppMetadata(
                bundleID: bundleID,
                displayName: bundleID,
                version: "1.0",
                shortVersion: "1.0",
                ipaSize: 1024,
                archivedAt: Date(),
                sourceDeviceName: nil,
                sourceDeviceVersion: nil
            ),
            ipaURL: url,
            iconData: nil
        )
    }

    private func makeViewModel(
        service: MockiMobileDeviceService = MockiMobileDeviceService(),
        bundleID: String = "com.test.App"
    ) -> InstallFromArchiveViewModel {
        InstallFromArchiveViewModel(app: makeApp(bundleID: bundleID), service: service)
    }

    // MARK: - canInstall gate

    func testCanInstall_isFalse_whenNoDeviceConnected() {
        let vm = makeViewModel()
        XCTAssertFalse(vm.canInstall, "canInstall should be false when no device is connected")
    }

    // MARK: - beginInstall no-device

    func testBeginInstall_noDevice_isNoOp() async {
        let service = MockiMobileDeviceService()
        let vm = makeViewModel(service: service)

        await vm.beginInstall()

        XCTAssertEqual(service.installIPACallCount, 0)
        XCTAssertFalse(vm.installDone)
        XCTAssertFalse(vm.isInstalling)
        XCTAssertNil(vm.installError)
    }

    // MARK: - Observation lifecycle

    func testStartObservingDevice_thenStop_doesNotLeakTask() async {
        let service = MockiMobileDeviceService()
        service.operationDelay = 0.01
        let vm = makeViewModel(service: service)

        vm.startObservingDevice()
        // Immediate stop must be safe and idempotent.
        vm.stopObservingDevice()
        vm.stopObservingDevice()

        // Allow any in-flight tick to complete; we just want to assert no crash
        // and no device leak.
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(vm.device)
    }
}
