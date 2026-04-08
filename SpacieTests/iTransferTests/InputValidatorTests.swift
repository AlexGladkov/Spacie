import XCTest
@testable import Spacie

// MARK: - InputValidatorTests

final class InputValidatorTests: XCTestCase {

    // MARK: - UDID Validation

    func testValidUDID_40HexChars_passes() throws {
        let udid = "00008110001A35E22EF8801E00008110001A35E2"
        XCTAssertNoThrow(try InputValidator.validateUDID(udid))
    }

    func testValidUDID_networkFormat_passes() throws {
        // Wi-Fi/network pairing format: UUID-style with hyphens (36 chars)
        let udid = "00008110-001A-35E2-2EF8-801E00008110"
        XCTAssertNoThrow(try InputValidator.validateUDID(udid))
    }

    func testValidUDID_25Chars_passes() throws {
        let udid = "00008110001A35E22EF8801E0"
        XCTAssertNoThrow(try InputValidator.validateUDID(udid))
    }

    func testInvalidUDID_tooShort_throws() {
        let udid = "00008110001A35E22EF8"
        XCTAssertThrowsError(try InputValidator.validateUDID(udid)) { error in
            guard case InputValidationError.invalidUDID = error else {
                return XCTFail("Expected invalidUDID, got \(error)")
            }
        }
    }

    func testInvalidUDID_tooLong_throws() {
        let udid = String(repeating: "A", count: 41)
        XCTAssertThrowsError(try InputValidator.validateUDID(udid)) { error in
            guard case InputValidationError.invalidUDID = error else {
                return XCTFail("Expected invalidUDID, got \(error)")
            }
        }
    }

    func testInvalidUDID_shellMetachars_throws() {
        let udid = "00008110001A35E22EF8801E;rm -rf /"
        XCTAssertThrowsError(try InputValidator.validateUDID(udid)) { error in
            guard case InputValidationError.invalidUDID = error else {
                return XCTFail("Expected invalidUDID, got \(error)")
            }
        }
    }

    func testInvalidUDID_empty_throws() {
        XCTAssertThrowsError(try InputValidator.validateUDID("")) { error in
            guard case InputValidationError.invalidUDID = error else {
                return XCTFail("Expected invalidUDID, got \(error)")
            }
        }
    }

    func testValidateUDID_returnsInputUnchanged() throws {
        let udid = "00008110001A35E22EF8801E00008110001A35E2"
        let result = try InputValidator.validateUDID(udid)
        XCTAssertEqual(result, udid)
    }

    // MARK: - Bundle ID Validation

    func testValidBundleID_twoSegments_passes() throws {
        XCTAssertNoThrow(try InputValidator.validateBundleID("com.example"))
    }

    func testValidBundleID_threeSegments_passes() throws {
        XCTAssertNoThrow(try InputValidator.validateBundleID("com.example.MyApp"))
    }

    func testValidBundleID_withHyphens_passes() throws {
        XCTAssertNoThrow(try InputValidator.validateBundleID("org.ietf.http-client"))
    }

    func testValidBundleID_numeric_passes() throws {
        XCTAssertNoThrow(try InputValidator.validateBundleID("com.1password.1password"))
    }

    func testInvalidBundleID_singleSegment_throws() {
        XCTAssertThrowsError(try InputValidator.validateBundleID("MyApp")) { error in
            guard case InputValidationError.invalidBundleID = error else {
                return XCTFail("Expected invalidBundleID, got \(error)")
            }
        }
    }

    func testInvalidBundleID_leadingDot_throws() {
        XCTAssertThrowsError(try InputValidator.validateBundleID(".com.example")) { error in
            guard case InputValidationError.invalidBundleID = error else {
                return XCTFail("Expected invalidBundleID, got \(error)")
            }
        }
    }

    func testInvalidBundleID_emptySegment_throws() {
        XCTAssertThrowsError(try InputValidator.validateBundleID("com..example")) { error in
            guard case InputValidationError.invalidBundleID = error else {
                return XCTFail("Expected invalidBundleID, got \(error)")
            }
        }
    }

    func testInvalidBundleID_shellInjection_throws() {
        XCTAssertThrowsError(try InputValidator.validateBundleID("com.example;cat /etc/passwd")) { error in
            guard case InputValidationError.invalidBundleID = error else {
                return XCTFail("Expected invalidBundleID, got \(error)")
            }
        }
    }

    func testInvalidBundleID_tooLong_throws() {
        // 160 characters — over the 155-char limit
        let tooLong = "com." + String(repeating: "a", count: 156)
        XCTAssertThrowsError(try InputValidator.validateBundleID(tooLong)) { error in
            guard case InputValidationError.invalidBundleID = error else {
                return XCTFail("Expected invalidBundleID, got \(error)")
            }
        }
    }

    func testValidateBundleID_returnsInputUnchanged() throws {
        let bundleID = "com.example.MyApp"
        let result = try InputValidator.validateBundleID(bundleID)
        XCTAssertEqual(result, bundleID)
    }

    // MARK: - Display Name Sanitization

    func testSanitizeDisplayName_normalString_unchanged() {
        let name = "iPhone 15 Pro"
        XCTAssertEqual(InputValidator.sanitizeDisplayName(name), name)
    }

    func testSanitizeDisplayName_stripsControlChars() {
        let name = "Bad\u{0001}Name\u{001F}"
        let result = InputValidator.sanitizeDisplayName(name)
        XCTAssertEqual(result, "BadName")
    }

    func testSanitizeDisplayName_preservesSpace() {
        let name = "Hello World"
        XCTAssertEqual(InputValidator.sanitizeDisplayName(name), "Hello World")
    }

    func testSanitizeDisplayName_stripsBidiOverrides() {
        // U+202E = RLO (Right-to-Left Override)
        let name = "App\u{202E}Name"
        let result = InputValidator.sanitizeDisplayName(name)
        XCTAssertFalse(result.unicodeScalars.contains { $0.value == 0x202E })
    }

    func testSanitizeDisplayName_stripsBidiIsolates() {
        // U+2066 = LRI
        let name = "App\u{2066}Name"
        let result = InputValidator.sanitizeDisplayName(name)
        XCTAssertFalse(result.unicodeScalars.contains { $0.value == 0x2066 })
    }

    func testSanitizeDisplayName_truncatesAtMaxLength() {
        let name = String(repeating: "x", count: 300)
        let result = InputValidator.sanitizeDisplayName(name, maxLength: 255)
        XCTAssertEqual(result.count, 255)
    }

    func testSanitizeDisplayName_exactlyMaxLength_notTruncated() {
        let name = String(repeating: "x", count: 255)
        let result = InputValidator.sanitizeDisplayName(name, maxLength: 255)
        XCTAssertEqual(result.count, 255)
    }

    func testSanitizeDisplayName_emptyString_returnsEmpty() {
        XCTAssertEqual(InputValidator.sanitizeDisplayName(""), "")
    }

    // MARK: - Safe Archive Path

    func testSafeArchivePath_validInputs_noTraversal() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let archiveDir = tempDir.appendingPathComponent("testArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveDir) }

        let result = try InputValidator.safeArchivePath(
            archiveDir: archiveDir,
            displayName: "My Cool App"
        )

        // Directory should be inside archiveDir
        let canonical = archiveDir.standardizedFileURL.path
        XCTAssertTrue(result.directory.standardizedFileURL.path.hasPrefix(canonical))
        XCTAssertTrue(result.ipaFile.standardizedFileURL.path.hasPrefix(canonical))
        // IPA file should end with .ipa
        XCTAssertEqual(result.ipaFile.pathExtension, "ipa")
    }

    func testSafeArchivePath_nonExistentDir_throws() {
        let nonExistent = URL(fileURLWithPath: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertThrowsError(
            try InputValidator.safeArchivePath(archiveDir: nonExistent, displayName: "App")
        ) { error in
            guard case InputValidationError.invalidArchiveDirectory = error else {
                return XCTFail("Expected invalidArchiveDirectory, got \(error)")
            }
        }
    }

    func testSafeArchivePath_directoriesAreUUIDNamed() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let archiveDir = tempDir.appendingPathComponent("testArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveDir) }

        let result1 = try InputValidator.safeArchivePath(archiveDir: archiveDir, displayName: "App")
        let result2 = try InputValidator.safeArchivePath(archiveDir: archiveDir, displayName: "App")

        // Each call produces a unique directory (UUID-named)
        XCTAssertNotEqual(result1.directory, result2.directory)
    }

    func testSafeArchivePath_dangerousDisplayName_sanitised() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let archiveDir = tempDir.appendingPathComponent("testArchive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveDir) }

        let result = try InputValidator.safeArchivePath(
            archiveDir: archiveDir,
            displayName: "../../etc/passwd"
        )

        // The IPA filename should not contain path-separators or dots-only
        let filename = result.ipaFile.deletingPathExtension().lastPathComponent
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(".."))
    }
}
