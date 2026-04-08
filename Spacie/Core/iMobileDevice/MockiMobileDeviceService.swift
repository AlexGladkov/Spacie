import Foundation

// MARK: - MockiMobileDeviceService

/// In-memory mock of ``iMobileDeviceProtocol`` for use in unit tests and
/// SwiftUI previews.
///
/// Configure its properties before the system-under-test calls any methods.
/// All mutable properties are `var` so tests can mutate them freely.
///
/// ## Usage in unit tests
/// ```swift
/// let mock = MockiMobileDeviceService()
/// mock.devicesToReturn = [DeviceInfo(...)]
/// mock.appsToReturn = [AppInfo(...)]
/// let vm = iTransferViewModel(service: mock, archive: MockAppArchiveService())
/// await vm.loadSourceApps()
/// XCTAssertEqual(vm.availableApps.count, 1)
/// ```
///
/// ## Usage in SwiftUI previews
/// ```swift
/// #Preview {
///     iTransferView(viewModel: iTransferViewModel(
///         service: MockiMobileDeviceService.withSampleData(),
///         archive: MockAppArchiveService()
///     ))
/// }
/// ```
final class MockiMobileDeviceService: iMobileDeviceProtocol, @unchecked Sendable {

    // MARK: - Configurable State

    /// Returned by ``checkDependencies()``.
    var dependencyStatusToReturn: DependencyStatus = .homebrewMissing

    /// Returned by ``listDevices()`` and used by ``observeDevices(pollingInterval:)``.
    var devicesToReturn: [DeviceInfo] = []

    /// Returned by ``listApps(udid:)``.
    var appsToReturn: [AppInfo] = []

    /// If set, every throwing method throws this error.
    var errorToThrow: (any Error)?

    /// Delay in seconds simulated during ``extractIPA`` and ``installIPA``.
    var operationDelay: TimeInterval = 0.05

    /// Bundle IDs that should fail during ``installIPA``.
    var installationFailures: Set<String> = []

    /// Events emitted sequentially by ``observeDevices(pollingInterval:)``.
    var deviceEventSequence: [DeviceEvent] = []

    // MARK: - Apple ID Auth Configuration

    /// Value returned by ``checkAppleIDAuth()``.
    var appleIDAuthenticatedToReturn = false

    /// If `true`, ``loginAppleID(email:password:authCode:)`` throws ``iMobileDeviceError/authFailed(reason:)``.
    var shouldFailAppleIDLogin = false

    // MARK: - Call Counters (for assertions)

    private(set) var checkDependenciesCallCount = 0
    private(set) var installDependenciesCallCount = 0
    private(set) var listDevicesCallCount = 0
    private(set) var listAppsCallCount = 0
    private(set) var extractIPACallCount = 0
    private(set) var installIPACallCount = 0
    private(set) var transferAppsCallCount = 0
    private(set) var checkAppleIDAuthCallCount = 0
    private(set) var loginAppleIDCallCount = 0

    // MARK: - iMobileDeviceProtocol

    func checkDependencies() async -> DependencyStatus {
        checkDependenciesCallCount += 1
        return dependencyStatusToReturn
    }

    func checkAppleIDAuth() async -> Bool {
        checkAppleIDAuthCallCount += 1
        return appleIDAuthenticatedToReturn
    }

    func loginAppleID(email: String, password: String, authCode: String?) async throws {
        loginAppleIDCallCount += 1
        if shouldFailAppleIDLogin {
            throw iMobileDeviceError.authFailed(reason: "Mock: authentication failed")
        }
        if let error = errorToThrow { throw error }
    }

    func installDependencies(
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        installDependenciesCallCount += 1
        if let error = errorToThrow { throw error }
        onLine("Mock: Installing libimobiledevice...")
        try? await Task.sleep(for: .seconds(operationDelay))
        onLine("Mock: Done.")
    }

    func listDevices() async throws -> [DeviceInfo] {
        listDevicesCallCount += 1
        if let error = errorToThrow { throw error }
        return devicesToReturn
    }

    func observeDevices(pollingInterval: TimeInterval) -> AsyncStream<DeviceEvent> {
        let events = deviceEventSequence
        let delay = max(0.01, pollingInterval)
        return AsyncStream { continuation in
            let task = Task {
                for event in events {
                    guard !Task.isCancelled else { break }
                    try? await Task.sleep(for: .seconds(delay))
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func validateTrust(udid: String) async -> TrustState {
        .trusted
    }

    func listApps(udid: String) async throws -> [AppInfo] {
        listAppsCallCount += 1
        if let error = errorToThrow { throw error }
        return appsToReturn
    }

    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        extractIPACallCount += 1
        if let error = errorToThrow { throw error }

        // Simulate progress steps.
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            guard !Task.isCancelled else { throw iMobileDeviceError.cancelled }
            try? await Task.sleep(for: .seconds(operationDelay))
            progressHandler(step)
        }

        let fakeIPA = destinationDir.appendingPathComponent("\(bundleID).ipa")
        // Create an empty placeholder so callers that check fileExists pass.
        FileManager.default.createFile(atPath: fakeIPA.path, contents: Data())
        return fakeIPA
    }

    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        installIPACallCount += 1
        if let error = errorToThrow { throw error }

        let bundleID = ipaPath.deletingPathExtension().lastPathComponent
        if installationFailures.contains(bundleID) {
            throw iMobileDeviceError.installFailed(
                bundleID: bundleID,
                reason: "Mock: FairPlay verification failed — Apple ID mismatch"
            )
        }

        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            guard !Task.isCancelled else { throw iMobileDeviceError.cancelled }
            try? await Task.sleep(for: .seconds(operationDelay))
            progressHandler(step)
        }
    }

    func transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: [AppInfo],
        archiveDir: URL?,
        shouldInstall: Bool
    ) -> AsyncThrowingStream<TransferProgress, Error> {
        transferAppsCallCount += 1
        let delay = operationDelay
        let failures = installationFailures
        return AsyncThrowingStream { continuation in
            let task = Task {
                var items = apps.map { TransferItem(id: $0.bundleID, app: $0) }
                for i in items.indices {
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: iMobileDeviceError.cancelled)
                        return
                    }
                    items[i].phase = .extracting
                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                    try? await Task.sleep(for: .seconds(delay))

                    if failures.contains(items[i].app.bundleID) {
                        items[i].phase = .failed
                        items[i].error = .installFailed(
                            bundleID: items[i].app.bundleID,
                            reason: "Mock: install failure"
                        )
                    } else {
                        items[i].phase = .completed
                        items[i].progress = 1.0
                    }
                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Sample Data Factory

    /// Returns a mock pre-configured with realistic sample data for SwiftUI previews.
    static func withSampleData() -> MockiMobileDeviceService {
        let mock = MockiMobileDeviceService()
        mock.dependencyStatusToReturn = .ready(ToolPaths(
            ideviceId: "/opt/homebrew/bin/idevice_id",
            ideviceInfo: "/opt/homebrew/bin/ideviceinfo",
            ideviceinstaller: "/opt/homebrew/bin/ideviceinstaller",
            idevicepair: "/opt/homebrew/bin/idevicepair",
            brew: "/opt/homebrew/bin/brew",
            ipatool: "/opt/homebrew/bin/ipatool"
        ))
        mock.devicesToReturn = [
            DeviceInfo(
                udid: "00008030-001A2B3C4D5E6F70",
                deviceName: "iPhone Artyom",
                productType: "iPhone16,1",
                productVersion: "18.3.1",
                buildVersion: "22D72"
            )
        ]
        mock.appsToReturn = [
            AppInfo(
                bundleID: "ru.sberbank.online",
                displayName: "СберБанк",
                version: "15.3.1",
                shortVersion: "15.3",
                ipaSize: 52_428_800,
                iconData: nil
            ),
            AppInfo(
                bundleID: "com.tinkoff.bank",
                displayName: "Т‑Банк",
                version: "6.12.0",
                shortVersion: "6.12",
                ipaSize: 47_185_920,
                iconData: nil
            ),
            AppInfo(
                bundleID: "ru.vtb24.mobilebanking.ios",
                displayName: "ВТБ Онлайн",
                version: "22.5.0",
                shortVersion: "22.5",
                ipaSize: 61_865_984,
                iconData: nil
            ),
        ]
        return mock
    }
}

// MARK: - MockAppArchiveService

/// In-memory mock of ``AppArchiveProtocol`` for use in unit tests and
/// SwiftUI previews.
final class MockAppArchiveService: AppArchiveProtocol, @unchecked Sendable {

    // MARK: - Configurable State

    var archivedAppsToReturn: [ArchivedApp] = []
    var errorToThrow: (any Error)?

    // MARK: - Call Counters

    private(set) var listArchivedAppsCallCount = 0
    private(set) var archiveIPACallCount = 0
    private(set) var deleteArchiveCallCount = 0
    private(set) var totalArchiveSizeCallCount = 0

    // MARK: - AppArchiveProtocol

    nonisolated var archiveDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MockArchive")
    }

    func listArchivedApps() async throws -> [ArchivedApp] {
        listArchivedAppsCallCount += 1
        if let error = errorToThrow { throw error }
        return archivedAppsToReturn
    }

    func archiveIPA(
        ipaPath: URL,
        metadata: ArchivedAppMetadata,
        overwrite: Bool
    ) async throws -> URL {
        archiveIPACallCount += 1
        if let error = errorToThrow { throw error }
        let fakeURL = archiveDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("\(metadata.displayName).ipa")
        return fakeURL
    }

    func deleteArchive(id: String) async throws {
        deleteArchiveCallCount += 1
        if let error = errorToThrow { throw error }
        archivedAppsToReturn.removeAll { $0.id == id }
    }

    func totalArchiveSize() async throws -> UInt64 {
        totalArchiveSizeCallCount += 1
        if let error = errorToThrow { throw error }
        return archivedAppsToReturn.reduce(0) { $0 + $1.metadata.ipaSize }
    }
}
