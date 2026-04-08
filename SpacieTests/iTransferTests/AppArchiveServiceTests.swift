import XCTest
@testable import Spacie

// MARK: - AppArchiveServiceTests

final class AppArchiveServiceTests: XCTestCase {

    // MARK: - Helpers

    private var tempDir: URL!
    private var service: AppArchiveService!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Point service to tempDir via UserDefaults
        UserDefaults.standard.set(tempDir.path, forKey: "iOSArchiveDirectory")
        service = AppArchiveService()
    }

    override func tearDown() async throws {
        try await super.tearDown()
        UserDefaults.standard.removeObject(forKey: "iOSArchiveDirectory")
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - archiveDirectory

    func testArchiveDirectory_usesUserDefaultsWhenSet() {
        XCTAssertEqual(service.archiveDirectory.path, tempDir.path)
    }

    func testArchiveDirectory_fallsBackToDefault_whenNotSet() {
        UserDefaults.standard.removeObject(forKey: "iOSArchiveDirectory")
        let fresh = AppArchiveService()
        XCTAssertEqual(fresh.archiveDirectory, AppArchiveService.defaultArchiveDirectory)
    }

    // MARK: - listArchivedApps

    func testListArchivedApps_emptyDirectory_returnsEmptyArray() async throws {
        let apps = try await service.listArchivedApps()
        XCTAssertTrue(apps.isEmpty)
    }

    func testListArchivedApps_nonExistentRoot_returnsEmptyArray() async throws {
        // Remove the directory to simulate a fresh install
        try FileManager.default.removeItem(at: tempDir)
        let apps = try await service.listArchivedApps()
        XCTAssertTrue(apps.isEmpty)
    }

    func testListArchivedApps_validEntry_returnsParsedApp() async throws {
        let entryID = UUID().uuidString
        let entryDir = tempDir.appendingPathComponent(entryID, isDirectory: true)
        try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)

        // Write a fake IPA
        let ipaURL = entryDir.appendingPathComponent("TestApp.ipa")
        try Data("fake ipa content".utf8).write(to: ipaURL)

        // Write metadata.json
        let metadata = ArchivedAppMetadata(
            bundleID: "com.example.TestApp",
            displayName: "Test App",
            version: "42",
            shortVersion: "2.1.0",
            ipaSize: 1024,
            archivedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDeviceName: "iPhone 15 Pro",
            sourceDeviceVersion: "18.0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        let metadataURL = entryDir.appendingPathComponent("metadata.json")
        try metadataData.write(to: metadataURL)

        let apps = try await service.listArchivedApps()
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].id, entryID)
        XCTAssertEqual(apps[0].bundleID, "com.example.TestApp")
        XCTAssertEqual(apps[0].displayName, "Test App")
        XCTAssertEqual(apps[0].metadata.shortVersion, "2.1.0")
        // Normalise both paths to handle /private/var ↔ /var symlink on macOS.
        XCTAssertEqual(
            apps[0].ipaURL.standardizedFileURL.path,
            ipaURL.standardizedFileURL.path
        )
        XCTAssertNil(apps[0].iconData)  // no icon.png created
    }

    func testListArchivedApps_skipsEntriesWithoutMetadata() async throws {
        // Create an entry directory with no metadata.json
        let entryDir = tempDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)
        try Data().write(to: entryDir.appendingPathComponent("SomeApp.ipa"))

        let apps = try await service.listArchivedApps()
        XCTAssertTrue(apps.isEmpty)
    }

    // MARK: - totalArchiveSize

    func testTotalArchiveSize_emptyDirectory_returnsZero() async throws {
        let size = try await service.totalArchiveSize()
        XCTAssertEqual(size, 0)
    }

    func testTotalArchiveSize_withFiles_returnsNonZero() async throws {
        let content = Data(repeating: 0xFF, count: 1024)
        try content.write(to: tempDir.appendingPathComponent("testfile.bin"))

        let size = try await service.totalArchiveSize()
        XCTAssertGreaterThan(size, 0)
    }

    // MARK: - deleteArchive

    func testDeleteArchive_validID_removesDirectory() async throws {
        let entryID = UUID().uuidString
        let entryDir = tempDir.appendingPathComponent(entryID, isDirectory: true)
        try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDir.path))

        try await service.deleteArchive(id: entryID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDir.path))
    }

    func testDeleteArchive_pathTraversalAttempt_throws() async {
        await XCTAssertThrowsAsyncError(
            try await service.deleteArchive(id: "../../../etc")
        )
    }

    func testDeleteArchive_embeddedSlash_throws() async {
        await XCTAssertThrowsAsyncError(
            try await service.deleteArchive(id: "valid/../../escape")
        )
    }
}

// MARK: - Async XCTAssert Helpers

/// Asserts that the async expression throws any error.
private func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // success
    }
}
