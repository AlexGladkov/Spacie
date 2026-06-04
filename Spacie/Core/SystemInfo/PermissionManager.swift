import Foundation
import AppKit
import SpacieKit

// MARK: - PermissionManager

/// Checks and manages Full Disk Access (FDA) permission status.
///
/// Delegates actual permission checking to KMP `SpaPermissionChecker`.
/// `@MainActor` isolated so the `@Observable` `hasFullDiskAccess` write is
/// guaranteed to happen on the main thread — fixes the data race where
/// `checkFullDiskAccess()` (callable from any thread) updated SwiftUI state
/// without isolation.
@MainActor
@Observable
final class PermissionManager {

    // MARK: - State

    /// Whether the application currently has Full Disk Access.
    private(set) var hasFullDiskAccess: Bool = false

    // MARK: - KMP

    private let checker = SpaPermissionChecker()

    // MARK: - Public API

    /// Probes TCC-protected paths to determine if Full Disk Access is granted.
    @discardableResult
    func checkFullDiskAccess() -> Bool {
        let result = checker.checkFullDiskAccess()
        hasFullDiskAccess = result
        return result
    }

    /// Opens System Settings directly to the Full Disk Access privacy pane.
    func openFullDiskAccessSettings() {
        checker.openFullDiskAccessSettings()
    }

    /// Opens System Settings directly to the Storage management pane.
    func openStorageSettings() {
        checker.openStorageSettings()
    }
}
