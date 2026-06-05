import Foundation
import SpacieKit

// MARK: - KMPErrorMapper

/// Maps Kotlin Multiplatform `SpaSpacieError` subclasses (surfaced through
/// Swift as `NSError` with the original Kotlin object available via
/// `.kotlinException`) to the Swift-native ``iMobileDeviceError``.
///
/// Extracted from `KMPDeviceServiceAdapter` so:
/// 1. The error-mapping logic is unit-testable in isolation
///    (`KMPErrorMapperTests`).
/// 2. Future adapters (e.g. for `SpaScanOrchestratorApi`) can reuse the
///    same mapping table.
enum KMPErrorMapper {

    /// Map an arbitrary `Error` thrown by a KMP call to the strongly typed
    /// ``iMobileDeviceError`` understood by the iTransfer feature.
    static func map(_ error: Error) -> iMobileDeviceError {
        let nsError = error as NSError
        let kotlinException: Any = nsError.kotlinException ?? error
        return dispatch(kotlinException, fallbackCode: Int32(nsError.code), fallbackMessage: error.localizedDescription)
    }

    /// Test/preview entry point — accepts the raw Kotlin throwable directly
    /// (KMP-generated `SpaSpacieError.*` subclasses are plain `NSObject`s
    /// without `Error` conformance until wrapped by the KMP runtime).
    ///
    /// Tests construct a `SpaSpacieError` and pass it here to verify
    /// the mapping branches without spinning up a real KMP call.
    static func mapKotlinThrowable(_ kotlinException: AnyObject) -> iMobileDeviceError {
        dispatch(kotlinException, fallbackCode: -1, fallbackMessage: "Kotlin throwable: \(type(of: kotlinException))")
    }

    // MARK: - Dispatch core

    /// Single source of truth for the `as?` cascade. Inputs can be `NSError`,
    /// `Error`, or a raw KMP `SpaSpacieError` instance — every branch uses
    /// `is`/`as?` against the kotlin class, so any of them works.
    private static func dispatch(
        _ kotlinException: Any,
        fallbackCode: Int32,
        fallbackMessage: String
    ) -> iMobileDeviceError {

        if kotlinException is SpaSpacieError.SpaSpacieErrorPackageManagerNotInstalled {
            return .homebrewNotInstalled
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDependencyMissing {
            return .dependencyMissing(e.tools)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDependencyInstallFailed {
            return .dependencyInstallFailed(reason: e.reason)
        }

        if kotlinException is SpaSpacieError.SpaSpacieErrorTwoFactorRequired {
            return .twoFactorRequired
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorAuthFailed {
            return .authFailed(reason: e.reason)
        }

        if kotlinException is SpaSpacieError.SpaSpacieErrorNotAuthenticated {
            return .notAuthenticated
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceNotFound {
            return .deviceNotFound(udid: e.udid)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceNotTrusted {
            return .deviceNotTrusted(udid: e.udid, name: e.name)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceDisconnected {
            return .deviceDisconnected(udid: e.udid, during: e.during)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorExtractionFailed {
            return .extractionFailed(bundleID: e.bundleID, reason: e.reason)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInstallFailed {
            return .installFailed(bundleID: e.bundleID, reason: e.reason)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorIpaFileNotFound {
            return .ipaFileNotFound(path: e.path)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorArchiveWriteFailed {
            return .archiveWriteFailed(path: e.path, reason: e.reason)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorProcessExitedWithError {
            return .processExitedWithError(tool: e.tool, exitCode: e.exitCode, stderr: e.stderr)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorProcessTimeout {
            return .processTimeout(tool: e.tool, timeout: e.timeout)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorAppListParseFailed {
            return .appListParseFailed(reason: e.reason, rawOutput: e.rawOutput)
        }

        if kotlinException is SpaSpacieError.SpaSpacieErrorCancelled {
            return .cancelled
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInsufficientDiskSpace {
            let required = e.required >= 0 ? UInt64(e.required) : 0
            let available = e.available >= 0 ? UInt64(e.available) : 0
            return .insufficientDiskSpace(required: required, available: available)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInvalidUDID {
            return .invalidUDID(udid: e.udid)
        }

        if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInvalidBundleID {
            return .invalidBundleID(bundleID: e.bundleID)
        }

        // Scan/Duplicate errors — not expected from DeviceService, but map
        // them gracefully if they ever surface through this path.
        if kotlinException is SpaSpacieError.SpaSpacieErrorScanFailed
            || kotlinException is SpaSpacieError.SpaSpacieErrorScanCancelled
            || kotlinException is SpaSpacieError.SpaSpacieErrorPathNotAccessible
            || kotlinException is SpaSpacieError.SpaSpacieErrorDuplicateReadFailed
            || kotlinException is SpaSpacieError.SpaSpacieErrorDuplicateCancelled {
            return .processExitedWithError(tool: "KMP", exitCode: -1, stderr: fallbackMessage)
        }

        // Generic fallback: surface the localised description with the raw
        // error code so consumers retain debug information.
        return .processExitedWithError(
            tool: "KMP",
            exitCode: fallbackCode,
            stderr: fallbackMessage
        )
    }
}
