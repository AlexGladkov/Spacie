import SwiftUI

// MARK: - Environment Keys for iMobileDevice + AppArchive services

/// SwiftUI `Environment` keys for the iOS device + archive services. Inject
/// mocks for previews and tests; the defaults forward to the KMP-backed
/// implementations.
///
/// Example usage in a preview:
///
/// ```swift
/// #Preview {
///     iTransferView()
///         .environment(\.iMobileDeviceService, MockiMobileDeviceService().withSampleData())
///         .environment(\.appArchiveService, MockAppArchiveService())
/// }
/// ```
///
/// Without these keys, every view-model fell back to `KMPDeviceServiceAdapter()`
/// and `AppArchiveService()` via constructor defaults, which made previews and
/// tests for the wizard impossible without subclassing the VM itself.
///
/// Default singletons are stored in main-actor isolated holders and accessed
/// via `MainActor.assumeIsolated` — SwiftUI Environment reads happen during
/// View body evaluation, which is main-actor isolated.

/// Process-wide singletons for the KMP-backed device service and archive
/// service. Exposed as `internal` so view-model `init` defaults can reuse the
/// same instances when SwiftUI re-creates `@State` view-models (otherwise each
/// instantiation spun up a fresh `KMPDeviceServiceAdapter` — i.e. a whole new
/// KMP `DeviceServiceImpl` + `IpaToolClient` + `IDeviceClient` stack).
@MainActor
enum SharedDeviceServices {
    // `lazy let` in Swift: initializer runs ONCE on first access. The
    // KMPDeviceServiceAdapter constructor synchronously probes Homebrew
    // paths via NSFileManager.fileExistsAtPath — those stat calls are
    // cheap individually but happen on MainActor. Documented trade-off:
    // first-open of the iTransfer wizard pays this latency once;
    // subsequent accesses are free. A truly async init would require
    // changing the iMobileDeviceProtocol surface to expose a "ready"
    // future, which is out of scope for this audit pass.
    static let device: any iMobileDeviceProtocol = KMPDeviceServiceAdapter()
    static let archive: any AppArchiveProtocol = AppArchiveService()

    /// Warm the singletons from a non-blocking caller. Apps that know they
    /// will need the device service (e.g. on app launch) can call this from
    /// a `Task.detached` so the first-open latency is paid in the
    /// background instead of when the user taps "Transfer iOS Apps".
    static func warm() {
        _ = device
        _ = archive
    }
}

private struct iMobileDeviceServiceKey: EnvironmentKey {
    static var defaultValue: any iMobileDeviceProtocol {
        MainActor.assumeIsolated { SharedDeviceServices.device }
    }
}

private struct AppArchiveServiceKey: EnvironmentKey {
    static var defaultValue: any AppArchiveProtocol {
        MainActor.assumeIsolated { SharedDeviceServices.archive }
    }
}

extension EnvironmentValues {

    var iMobileDeviceService: any iMobileDeviceProtocol {
        get { self[iMobileDeviceServiceKey.self] }
        set { self[iMobileDeviceServiceKey.self] = newValue }
    }

    var appArchiveService: any AppArchiveProtocol {
        get { self[AppArchiveServiceKey.self] }
        set { self[AppArchiveServiceKey.self] = newValue }
    }
}
