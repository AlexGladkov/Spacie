import Foundation
import AppKit
import SpacieKit

// MARK: - PermissionManaging

/// Abstraction over Full Disk Access permission checks so SwiftUI views can
/// swap in mock implementations for previews and tests without depending on
/// the real KMP service.
///
/// Methods are marked `@MainActor` individually (not the protocol) so the
/// type can be used as an `EnvironmentKey.Value` — those keys cannot have
/// main-actor-isolated default values.
protocol PermissionManaging: AnyObject, Sendable {
    @MainActor var hasFullDiskAccess: Bool { get }

    @MainActor @discardableResult
    func checkFullDiskAccess() -> Bool

    @MainActor func openFullDiskAccessSettings()
    @MainActor func openStorageSettings()
}

// MARK: - PermissionManager

/// Default implementation backed by KMP `SpaPermissionChecker`.
///
/// `@MainActor` isolated so the `@Observable` `hasFullDiskAccess` write is
/// guaranteed to happen on the main thread.
@MainActor
@Observable
final class PermissionManager: PermissionManaging {

    // MARK: - State

    private(set) var hasFullDiskAccess: Bool = false

    // MARK: - KMP

    private let checker: SpaPermissionChecker

    init(checker: SpaPermissionChecker = SpaSpacieFactory.shared.createPermissionChecker()) {
        self.checker = checker
    }

    // MARK: - Public API

    @discardableResult
    func checkFullDiskAccess() -> Bool {
        let result = checker.checkFullDiskAccess()
        hasFullDiskAccess = result
        return result
    }

    func openFullDiskAccessSettings() {
        checker.openFullDiskAccessSettings()
    }

    func openStorageSettings() {
        checker.openStorageSettings()
    }
}

// MARK: - MockPermissionManager

#if DEBUG
/// In-memory implementation for SwiftUI Previews and unit tests.
@MainActor
@Observable
final class MockPermissionManager: PermissionManaging {

    var hasFullDiskAccess: Bool

    private(set) var checkCallCount = 0
    private(set) var openFullDiskAccessCallCount = 0
    private(set) var openStorageCallCount = 0

    init(hasFullDiskAccess: Bool = true) {
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    @discardableResult
    func checkFullDiskAccess() -> Bool {
        checkCallCount += 1
        return hasFullDiskAccess
    }

    func openFullDiskAccessSettings() {
        openFullDiskAccessCallCount += 1
    }

    func openStorageSettings() {
        openStorageCallCount += 1
    }
}
#endif
