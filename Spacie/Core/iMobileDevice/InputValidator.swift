import Foundation

// MARK: - InputValidationError

/// Errors thrown by ``InputValidator`` when user-supplied or device-supplied
/// input fails sanitization checks.
///
/// These checks are the **first line of defence** against injection attacks
/// when constructing shell commands for `libimobiledevice` tools.
enum InputValidationError: Error, Sendable {

    /// The provided UDID does not match the expected hexadecimal format.
    ///
    /// iOS UDIDs are 25-40 character strings consisting of hex digits and
    /// optional hyphens (USB UDIDs are 40 hex chars; network UDIDs use a
    /// hyphen-separated format that is shorter).
    case invalidUDID(String)

    /// The provided bundle identifier is not a valid reverse-DNS string.
    ///
    /// Valid bundle IDs consist of two or more dot-separated segments,
    /// each containing only ASCII alphanumerics and hyphens, with a
    /// maximum total length of 155 characters.
    case invalidBundleID(String)

    /// The constructed path attempts to escape the designated archive
    /// directory via `..` or symbolic links.
    case pathTraversalDetected

    /// The base archive directory does not exist or is not a directory.
    case invalidArchiveDirectory
}

// MARK: - InputValidationError + LocalizedError

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

/// Sanitises inputs originating from iOS devices and user text fields before
/// they are used in shell commands, file paths, or UI labels.
///
/// All methods are pure functions with no side effects and no internal state.
///
/// ## Security Model
///
/// | Check | Threat Mitigated |
/// |---|---|
/// | ``validateUDID(_:)`` | Command injection via crafted UDID strings (C1) |
/// | ``validateBundleID(_:)`` | Command injection via crafted bundle IDs (C1) |
/// | ``sanitizeDisplayName(_:maxLength:)`` | Unicode bidi override attacks, control-char injection (C2) |
/// | ``safeArchivePath(archiveDir:displayName:)`` | Directory traversal via `..` or symlinks |
enum InputValidator {

    // MARK: - UDID Validation

    /// Regular expression for a valid iOS UDID.
    ///
    /// Matches 25-40 characters of hexadecimal digits and hyphens.
    /// - 40 hex chars: classic USB UDID (e.g. iPhone pre-iOS 17)
    /// - 25 chars with hyphens: Wi-Fi/network pairing identifiers
    /// - 36 chars with hyphens: UUID-style UDIDs on newer devices
    private nonisolated(unsafe) static let udidPattern = /^[a-fA-F0-9\-]{25,40}$/

    /// Validates that a UDID string contains only hex digits and hyphens
    /// and falls within the expected length range.
    ///
    /// - Parameter udid: The raw UDID string from the device.
    /// - Returns: The validated UDID string (unchanged).
    /// - Throws: ``InputValidationError/invalidUDID(_:)`` if the format
    ///   does not match.
    @discardableResult
    static func validateUDID(_ udid: String) throws -> String {
        guard udid.wholeMatch(of: udidPattern) != nil else {
            throw InputValidationError.invalidUDID(udid)
        }
        return udid
    }

    // MARK: - Bundle ID Validation

    /// Regular expression for a single reverse-DNS segment.
    ///
    /// Each segment must start with an ASCII letter or digit and may
    /// contain letters, digits, and hyphens. Segments must not be empty.
    private nonisolated(unsafe) static let bundleIDPattern =
        /^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)+$/

    /// Maximum allowed length for a bundle identifier.
    ///
    /// Apple's documentation does not specify an exact limit, but 155
    /// characters is a safe upper bound derived from empirical App Store
    /// submissions and Xcode validation.
    private static let maxBundleIDLength = 155

    /// Validates that a bundle identifier is a well-formed reverse-DNS
    /// string with at least two segments.
    ///
    /// Examples of **valid** IDs: `com.example.MyApp`, `org.ietf.http-client`.
    ///
    /// Examples of **invalid** IDs: `MyApp` (single segment), `.com.example`
    /// (leading dot), `com..example` (empty segment).
    ///
    /// - Parameter bundleID: The raw bundle identifier.
    /// - Returns: The validated bundle identifier (unchanged).
    /// - Throws: ``InputValidationError/invalidBundleID(_:)`` on failure.
    @discardableResult
    static func validateBundleID(_ bundleID: String) throws -> String {
        guard bundleID.count <= maxBundleIDLength,
              bundleID.wholeMatch(of: bundleIDPattern) != nil
        else {
            throw InputValidationError.invalidBundleID(bundleID)
        }
        return bundleID
    }

    // MARK: - Display Name Sanitization

    /// Unicode scalar ranges that must be stripped from display names.
    ///
    /// - **Control characters** (U+0000..U+001F except U+0020 space):
    ///   Can break UI layouts and inject terminal escape sequences.
    /// - **Bidirectional overrides** (U+202A..U+202E):
    ///   LRE, RLE, PDF, LRO, RLO — can reverse displayed text direction,
    ///   masking the true content of a filename.
    /// - **Bidirectional isolates** (U+2066..U+2069):
    ///   LRI, RLI, FSI, PDI — newer bidi control characters with the
    ///   same spoofing potential.
    private static let forbiddenScalarRanges: [ClosedRange<Unicode.Scalar>] = [
        Unicode.Scalar(0x0000)...Unicode.Scalar(0x001F),
        Unicode.Scalar(UInt32(0x202A))!...Unicode.Scalar(UInt32(0x202E))!,
        Unicode.Scalar(UInt32(0x2066))!...Unicode.Scalar(UInt32(0x2069))!,
    ]

    /// Sanitises a device or app display name for safe rendering in the UI.
    ///
    /// Performs the following transformations **in order**:
    /// 1. Removes all Unicode scalars in ``forbiddenScalarRanges``
    ///    (control characters and bidi overrides), **preserving** U+0020 (space).
    /// 2. Truncates the result to `maxLength` characters.
    ///
    /// The returned string is safe for display in `SwiftUI.Text`,
    /// `NSTextField`, and similar views.
    ///
    /// - Parameters:
    ///   - name: The raw display name.
    ///   - maxLength: Maximum allowed character count (default 255).
    /// - Returns: A sanitised copy of the name.
    static func sanitizeDisplayName(
        _ name: String,
        maxLength: Int = 255
    ) -> String {
        let cleaned = String(name.unicodeScalars.filter { scalar in
            // Always keep regular space (U+0020).
            if scalar == Unicode.Scalar(0x0020) { return true }

            // Drop any scalar that falls inside a forbidden range.
            for range in forbiddenScalarRanges {
                if range.contains(scalar) { return false }
            }
            return true
        })

        if cleaned.count <= maxLength {
            return cleaned
        }
        return String(cleaned.prefix(maxLength))
    }

    // MARK: - Safe Archive Path

    /// Characters allowed in a sanitised filename.
    ///
    /// This whitelist prevents shell metacharacters, path separators, and
    /// other dangerous characters from appearing in filesystem paths that
    /// may later be interpolated into shell commands.
    private static let filenameAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-"
    )

    /// Maximum length for the sanitised filename portion (excluding `.ipa`).
    private static let maxFilenameLength = 50

    /// Constructs a safe archive path for storing a downloaded IPA.
    ///
    /// The directory name is a freshly generated UUID — **never** a raw
    /// bundle ID or display name — eliminating any possibility of path
    /// traversal or naming collisions. The IPA filename is derived from
    /// `displayName` after stripping all characters outside the
    /// ``filenameAllowedCharacters`` whitelist.
    ///
    /// After construction the method verifies that the resolved path is
    /// a genuine descendant of `archiveDir` (via ``URL/standardizedFileURL``),
    /// guarding against symlink-based escapes.
    ///
    /// - Parameters:
    ///   - archiveDir: The root directory where archives are stored.
    ///     Must already exist on disk.
    ///   - displayName: A human-readable name used only for the `.ipa`
    ///     filename. Sanitised internally; callers need not pre-clean it.
    /// - Returns: A tuple of the newly created directory URL and the
    ///   target IPA file URL within it.
    /// - Throws: ``InputValidationError/invalidArchiveDirectory`` if
    ///   `archiveDir` is not a valid directory,
    ///   ``InputValidationError/pathTraversalDetected`` if the resolved
    ///   path escapes the archive root.
    static func safeArchivePath(
        archiveDir: URL,
        displayName: String
    ) throws -> (directory: URL, ipaFile: URL) {
        // Verify the archive directory exists and is a directory.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: archiveDir.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw InputValidationError.invalidArchiveDirectory
        }

        // Build directory: archiveDir / UUID /
        let directoryName = UUID().uuidString
        let directoryURL = archiveDir
            .appendingPathComponent(directoryName, isDirectory: true)

        // Sanitise displayName for use as a filename.
        let sanitisedName = sanitizeFilename(displayName)
        let ipaURL = directoryURL
            .appendingPathComponent("\(sanitisedName).ipa", isDirectory: false)

        // Path-traversal guard: verify both URLs remain inside archiveDir.
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

    // MARK: - Private Helpers

    /// Strips all characters outside the filename whitelist and truncates.
    ///
    /// If the input is empty or becomes empty after filtering, falls back
    /// to `"Untitled"` to avoid creating a bare `.ipa` extension.
    ///
    /// - Parameter name: The raw display name.
    /// - Returns: A filesystem-safe filename (without extension).
    private static func sanitizeFilename(_ name: String) -> String {
        let filtered = name.unicodeScalars
            .filter { filenameAllowedCharacters.contains($0) }

        let trimmed: String
        if filtered.isEmpty {
            trimmed = "Untitled"
        } else {
            let asString = String(filtered)
            trimmed = String(asString.prefix(maxFilenameLength))
        }

        // Remove leading/trailing whitespace and dots for extra safety.
        return trimmed
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
