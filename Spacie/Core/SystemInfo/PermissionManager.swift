import Foundation
import AppKit

// MARK: - PermissionManager

/// Checks and manages Full Disk Access (FDA) permission status.
///
/// Full Disk Access is required for Spacie to scan TCC-protected directories
/// such as `~/Library/Safari`, `~/Library/Mail`, and others. Without FDA,
/// these directories appear as "Restricted" in the scan results.
///
/// ## Detection Strategy
/// FDA is detected by attempting to read a known TCC-protected file.
/// `~/Library/Safari/Bookmarks.plist` is chosen because Safari is always
/// present on macOS and the file is consistently protected by TCC.
///
/// ## Deep Links
/// The manager provides convenience methods to open the relevant
/// System Settings panes via `x-apple.systempreferences` URL scheme.
@Observable
final class PermissionManager: @unchecked Sendable {

    // MARK: - State

    /// Whether the application currently has Full Disk Access.
    ///
    /// Updated by calling ``checkFullDiskAccess()``. The initial value
    /// is `false` until the first check completes.
    private(set) var hasFullDiskAccess: Bool = false

    // MARK: - TCC-Protected Probe Paths

    /// Paths known to be protected by TCC and requiring Full Disk Access.
    /// Ordered by likelihood of existence on a typical macOS installation.
    private static let probePathCandidates: [String] = [
        NSHomeDirectory() + "/Library/Safari/Bookmarks.plist",
        NSHomeDirectory() + "/Library/Safari/CloudTabs.db",
        NSHomeDirectory() + "/Library/Mail",
    ]

    // MARK: - Deep Link URLs

    /// URL scheme for the Full Disk Access pane in System Settings.
    private static let fullDiskAccessURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    /// URL scheme for the Storage management pane in System Settings.
    private static let storageSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.Storage"
    )!

    // MARK: - Public API

    /// Probes TCC-protected paths to determine if Full Disk Access is granted.
    ///
    /// Attempts to read attributes of known protected files. If any read
    /// succeeds, FDA is granted. If all reads fail with permission errors,
    /// FDA is not granted. Updates ``hasFullDiskAccess`` with the result.
    ///
    /// - Returns: `true` if FDA is granted, `false` otherwise.
    @discardableResult
    func checkFullDiskAccess() -> Bool {
        let fm = FileManager.default

        for path in Self.probePathCandidates {
            // Try to stat the file. If it does not exist, try the next candidate.
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: path, isDirectory: &isDir)

            if !exists {
                continue
            }

            // Attempt to read the file's attributes. If this succeeds, we have FDA.
            // If it fails with a permission error, we do not.
            let readable = fm.isReadableFile(atPath: path)
            if readable {
                hasFullDiskAccess = true
                return true
            } else {
                // Permission denied on a known TCC path => no FDA
                hasFullDiskAccess = false
                return false
            }
        }

        // None of the probe paths exist at all. This is unusual.
        // Assume FDA is granted since we cannot confirm either way,
        // and the scanner will surface restricted paths individually.
        hasFullDiskAccess = true
        return true
    }

    /// Opens System Settings directly to the Full Disk Access privacy pane.
    ///
    /// Uses the `x-apple.systempreferences` URL scheme. On macOS 15+ this
    /// opens the System Settings app (not the legacy System Preferences).
    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(Self.fullDiskAccessURL)
    }

    /// Opens System Settings directly to the Storage management pane.
    ///
    /// Useful for directing users to macOS built-in storage recommendations
    /// such as emptying Trash, optimizing storage, or reviewing large files.
    func openStorageSettings() {
        NSWorkspace.shared.open(Self.storageSettingsURL)
    }
}
