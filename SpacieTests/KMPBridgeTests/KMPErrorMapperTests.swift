import XCTest
import SpacieKit
@testable import Spacie

// MARK: - KMPErrorMapperTests

/// Verifies that every Kotlin `SpaSpacieError` subclass surfaces as the right
/// Swift-native ``iMobileDeviceError`` case, including the fallback path for
/// unknown errors.
///
/// KMP throws-suspend functions wrap Kotlin exceptions inside `NSError` with
/// the original Kotlin object available via `NSError.kotlinException`. These
/// tests construct the Kotlin exception directly and pass it through
/// `KMPErrorMapper.map(_:)` — that exercises both the `as?` cast and the
/// `nsError.kotlinException` fallback because Kotlin exceptions ARE NSErrors
/// in the bridged surface.
final class KMPErrorMapperTests: XCTestCase {

    func testPackageManagerNotInstalled_mapsToHomebrewNotInstalled() {
        let kmpError = SpaSpacieError.SpaSpacieErrorPackageManagerNotInstalled(
            managerName: "Homebrew",
            installUrl: "https://brew.sh"
        )
        guard case .homebrewNotInstalled = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .homebrewNotInstalled")
            return
        }
    }

    func testDependencyMissing_carriesToolsList() {
        let kmpError = SpaSpacieError.SpaSpacieErrorDependencyMissing(
            tools: ["idevice_id", "ipatool"]
        )
        guard case .dependencyMissing(let tools) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .dependencyMissing")
            return
        }
        XCTAssertEqual(tools, ["idevice_id", "ipatool"])
    }

    func testDependencyInstallFailed_carriesReason() {
        let kmpError = SpaSpacieError.SpaSpacieErrorDependencyInstallFailed(
            reason: "brew not in PATH"
        )
        guard case .dependencyInstallFailed(let reason) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .dependencyInstallFailed")
            return
        }
        XCTAssertEqual(reason, "brew not in PATH")
    }

    func testTwoFactorRequired_mapsTo2FACase() {
        guard case .twoFactorRequired =
                KMPErrorMapper.mapKotlinThrowable(SpaSpacieError.SpaSpacieErrorTwoFactorRequired())
        else {
            XCTFail("expected .twoFactorRequired")
            return
        }
    }

    func testAuthFailed_carriesReason() {
        let kmpError = SpaSpacieError.SpaSpacieErrorAuthFailed(reason: "bad password")
        guard case .authFailed(let reason) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .authFailed")
            return
        }
        XCTAssertEqual(reason, "bad password")
    }

    func testNotAuthenticated_mapsTo() {
        guard case .notAuthenticated =
                KMPErrorMapper.mapKotlinThrowable(SpaSpacieError.SpaSpacieErrorNotAuthenticated())
        else {
            XCTFail("expected .notAuthenticated")
            return
        }
    }

    func testDeviceNotFound_carriesUDID() {
        let kmpError = SpaSpacieError.SpaSpacieErrorDeviceNotFound(udid: "ABCD-1234")
        guard case .deviceNotFound(let udid) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .deviceNotFound")
            return
        }
        XCTAssertEqual(udid, "ABCD-1234")
    }

    func testDeviceNotTrusted_carriesUDIDAndName() {
        let kmpError = SpaSpacieError.SpaSpacieErrorDeviceNotTrusted(
            udid: "ABCD-1234",
            name: "iPhone Artyom"
        )
        guard case .deviceNotTrusted(let udid, let name) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .deviceNotTrusted")
            return
        }
        XCTAssertEqual(udid, "ABCD-1234")
        XCTAssertEqual(name, "iPhone Artyom")
    }

    func testDeviceDisconnected_carriesContext() {
        let kmpError = SpaSpacieError.SpaSpacieErrorDeviceDisconnected(
            udid: "ABCD-1234",
            during: "extract"
        )
        guard case .deviceDisconnected(let udid, let during) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .deviceDisconnected")
            return
        }
        XCTAssertEqual(udid, "ABCD-1234")
        XCTAssertEqual(during, "extract")
    }

    func testExtractionFailed_carriesBundleAndReason() {
        let kmpError = SpaSpacieError.SpaSpacieErrorExtractionFailed(
            bundleID: "com.example",
            reason: "ipatool error"
        )
        guard case .extractionFailed(let bundleID, let reason) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .extractionFailed")
            return
        }
        XCTAssertEqual(bundleID, "com.example")
        XCTAssertEqual(reason, "ipatool error")
    }

    func testInstallFailed_carriesBundleAndReason() {
        let kmpError = SpaSpacieError.SpaSpacieErrorInstallFailed(
            bundleID: "com.example",
            reason: "FairPlay"
        )
        guard case .installFailed(let bundleID, let reason) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .installFailed")
            return
        }
        XCTAssertEqual(bundleID, "com.example")
        XCTAssertEqual(reason, "FairPlay")
    }

    func testIpaFileNotFound_carriesPath() {
        let kmpError = SpaSpacieError.SpaSpacieErrorIpaFileNotFound(path: "/tmp/missing.ipa")
        guard case .ipaFileNotFound(let path) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .ipaFileNotFound")
            return
        }
        XCTAssertEqual(path, "/tmp/missing.ipa")
    }

    func testArchiveWriteFailed_carriesPathAndReason() {
        let kmpError = SpaSpacieError.SpaSpacieErrorArchiveWriteFailed(
            path: "/tmp/archive.ipa",
            reason: "disk full"
        )
        guard case .archiveWriteFailed(let path, let reason) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .archiveWriteFailed")
            return
        }
        XCTAssertEqual(path, "/tmp/archive.ipa")
        XCTAssertEqual(reason, "disk full")
    }

    func testProcessExitedWithError_carriesToolExitStderr() {
        let kmpError = SpaSpacieError.SpaSpacieErrorProcessExitedWithError(
            tool: "ipatool",
            exitCode: 42,
            stderr: "bad creds"
        )
        guard case .processExitedWithError(let tool, let exitCode, let stderr) =
                KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .processExitedWithError")
            return
        }
        XCTAssertEqual(tool, "ipatool")
        XCTAssertEqual(exitCode, 42)
        XCTAssertEqual(stderr, "bad creds")
    }

    func testProcessTimeout_carriesToolAndTimeout() {
        let kmpError = SpaSpacieError.SpaSpacieErrorProcessTimeout(
            tool: "ideviceinstaller",
            timeout: 30.0
        )
        guard case .processTimeout(let tool, let timeout) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .processTimeout")
            return
        }
        XCTAssertEqual(tool, "ideviceinstaller")
        XCTAssertEqual(timeout, 30.0, accuracy: 0.001)
    }

    func testAppListParseFailed_carriesReasonAndRaw() {
        let kmpError = SpaSpacieError.SpaSpacieErrorAppListParseFailed(
            reason: "invalid plist",
            rawOutput: "<broken>"
        )
        guard case .appListParseFailed(let reason, let rawOutput) =
                KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .appListParseFailed")
            return
        }
        XCTAssertEqual(reason, "invalid plist")
        XCTAssertEqual(rawOutput, "<broken>")
    }

    func testCancelled_mapsToCancelled() {
        guard case .cancelled = KMPErrorMapper.mapKotlinThrowable(SpaSpacieError.SpaSpacieErrorCancelled())
        else {
            XCTFail("expected .cancelled")
            return
        }
    }

    func testInsufficientDiskSpace_clampsNegativeValues() {
        let kmpError = SpaSpacieError.SpaSpacieErrorInsufficientDiskSpace(
            required: -1, available: -1
        )
        guard case .insufficientDiskSpace(let required, let available) =
                KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .insufficientDiskSpace")
            return
        }
        XCTAssertEqual(required, 0)
        XCTAssertEqual(available, 0)
    }

    func testInsufficientDiskSpace_preservesPositiveValues() {
        let kmpError = SpaSpacieError.SpaSpacieErrorInsufficientDiskSpace(
            required: 1024, available: 512
        )
        guard case .insufficientDiskSpace(let required, let available) =
                KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .insufficientDiskSpace")
            return
        }
        XCTAssertEqual(required, 1024)
        XCTAssertEqual(available, 512)
    }

    func testInvalidUDID_carriesUDID() {
        let kmpError = SpaSpacieError.SpaSpacieErrorInvalidUDID(udid: "bad-udid")
        guard case .invalidUDID(let udid) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .invalidUDID")
            return
        }
        XCTAssertEqual(udid, "bad-udid")
    }

    func testInvalidBundleID_carriesBundleID() {
        let kmpError = SpaSpacieError.SpaSpacieErrorInvalidBundleID(bundleID: "not.a.bundle")
        guard case .invalidBundleID(let bundleID) = KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .invalidBundleID")
            return
        }
        XCTAssertEqual(bundleID, "not.a.bundle")
    }

    // MARK: - Scan/Duplicate fallback branch

    func testScanFailed_mapsToGenericProcessError() {
        let kmpError = SpaSpacieError.SpaSpacieErrorScanFailed(path: "/x", reason: "EIO")
        guard case .processExitedWithError(let tool, let exitCode, _) =
                KMPErrorMapper.mapKotlinThrowable(kmpError) else {
            XCTFail("expected .processExitedWithError fallback")
            return
        }
        XCTAssertEqual(tool, "KMP")
        XCTAssertEqual(exitCode, -1)
    }

    // MARK: - Generic fallback branch

    func testNonSpaSpacieError_usesNSErrorFallback() {
        let plainError = NSError(
            domain: "MyDomain",
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        guard case .processExitedWithError(let tool, let exitCode, let stderr) =
                KMPErrorMapper.map(plainError) else {
            XCTFail("expected fallback .processExitedWithError")
            return
        }
        XCTAssertEqual(tool, "KMP")
        XCTAssertEqual(exitCode, 17)
        XCTAssertTrue(stderr.contains("boom"))
    }
}
