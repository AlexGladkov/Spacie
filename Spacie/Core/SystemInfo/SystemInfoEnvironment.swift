import SwiftUI

// MARK: - Environment Keys

/// SwiftUI `Environment` keys for the system-info managers. Inject mocks for
/// previews and tests; the defaults forward to KMP-backed singletons.
///
/// Example usage in a preview:
///
/// ```swift
/// #Preview {
///     ContentView()
///         .environment(\.permissionManager, MockPermissionManager(hasFullDiskAccess: true))
///         .environment(\.volumeManager, MockVolumeManager(volumes: SampleVolumes.macWithExternal))
///         .environment(\.trashManager, MockTrashManager())
/// }
/// ```
///
/// Default singletons are stored in main-actor isolated holders and accessed
/// via `MainActor.assumeIsolated` — SwiftUI Environment reads happen during
/// View body evaluation, which is main-actor isolated.

@MainActor
private enum DefaultManagers {
    static let permission: any PermissionManaging = PermissionManager()
    static let volume: any VolumeManaging = VolumeManager.shared
    static let trash: any TrashManaging = TrashManager()
}

private struct PermissionManagerKey: EnvironmentKey {
    static var defaultValue: any PermissionManaging {
        MainActor.assumeIsolated { DefaultManagers.permission }
    }
}

private struct VolumeManagerKey: EnvironmentKey {
    static var defaultValue: any VolumeManaging {
        MainActor.assumeIsolated { DefaultManagers.volume }
    }
}

private struct TrashManagerKey: EnvironmentKey {
    static var defaultValue: any TrashManaging {
        MainActor.assumeIsolated { DefaultManagers.trash }
    }
}

extension EnvironmentValues {

    var permissionManager: any PermissionManaging {
        get { self[PermissionManagerKey.self] }
        set { self[PermissionManagerKey.self] = newValue }
    }

    var volumeManager: any VolumeManaging {
        get { self[VolumeManagerKey.self] }
        set { self[VolumeManagerKey.self] = newValue }
    }

    var trashManager: any TrashManaging {
        get { self[TrashManagerKey.self] }
        set { self[TrashManagerKey.self] = newValue }
    }
}
