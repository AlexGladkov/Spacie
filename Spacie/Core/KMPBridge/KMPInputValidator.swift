import Foundation
import SpacieKit

// MARK: - InputValidationError

/// Errors thrown by ``InputValidator`` when user-supplied or device-supplied
/// input fails sanitization checks.
enum InputValidationError: Error, Sendable {
    case invalidUDID(String)
    case invalidBundleID(String)
    case pathTraversalDetected
    case invalidArchiveDirectory
}

extension InputValidationError: LocalizedError {

    var errorDescription: String? {
        switch self {
        case .invalidUDID(let udid):
            "Invalid UDID: \"\(udid)\" does not match [a-fA-F0-9-]{25,40}."
        case .invalidBundleID(let bundleID):
            "Invalid bundle ID: \"\(bundleID)\" is not a valid reverse-DNS identifier."
        case .pathTraversalDetected:
            "Path traversal detected: the constructed path escapes the archive directory."
        case .invalidArchiveDirectory:
            "The specified archive directory does not exist or is not a directory."
        }
    }
}

// MARK: - InputValidator

/// Delegates validation logic to KMP `SpaInputValidator` and keeps
/// filesystem-dependent operations (`safeArchivePath`) in Swift.
enum InputValidator {

    // MARK: - UDID Validation

    @discardableResult
    static func validateUDID(_ udid: String) throws -> String {
        do {
            return try SpaInputValidator.shared.validateUDID(udid: udid)
        } catch {
            throw InputValidationError.invalidUDID(udid)
        }
    }

    // MARK: - Bundle ID Validation

    @discardableResult
    static func validateBundleID(_ bundleID: String) throws -> String {
        do {
            return try SpaInputValidator.shared.validateBundleID(bundleID: bundleID)
        } catch {
            throw InputValidationError.invalidBundleID(bundleID)
        }
    }

    // MARK: - Display Name Sanitization

    static func sanitizeDisplayName(
        _ name: String,
        maxLength: Int = 255
    ) -> String {
        SpaInputValidator.shared.sanitizeDisplayName(name: name, maxLength: Int32(maxLength))
    }

    // MARK: - Safe Archive Path (Swift-only, uses FileManager + URL)

    static func safeArchivePath(
        archiveDir: URL,
        displayName: String
    ) throws -> (directory: URL, ipaFile: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: archiveDir.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw InputValidationError.invalidArchiveDirectory
        }

        let directoryName = UUID().uuidString
        let directoryURL = archiveDir
            .appendingPathComponent(directoryName, isDirectory: true)

        let sanitisedName = SpaInputValidator.shared.sanitizeFilename(name: displayName)
        let ipaURL = directoryURL
            .appendingPathComponent("\(sanitisedName).ipa", isDirectory: false)

        let canonicalBase = archiveDir.standardizedFileURL.path
        let canonicalDir = directoryURL.standardizedFileURL.path
        let canonicalFile = ipaURL.standardizedFileURL.path

        guard canonicalDir.hasPrefix(canonicalBase),
              canonicalFile.hasPrefix(canonicalBase)
        else {
            throw InputValidationError.pathTraversalDetected
        }

        return (directory: directoryURL, ipaFile: ipaURL)
    }
}
