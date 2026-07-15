// MARK: - Update Servicing
// Contract for in-app auto-update (Sparkle-backed in DIRECT builds).
// macOS 15+, Swift 6

import Foundation

// MARK: - UpdateServicing

/// Drives in-app application updates.
///
/// Backed by Sparkle in DIRECT (DMG) distribution — see ``UpdateService``.
/// A safe no-op implementation (``NoopUpdateService``) is used for App Store
/// builds (Sparkle self-update is disallowed there) and for SwiftUI previews.
///
/// Kept as a narrow protocol (ISP) so views depend only on the update surface,
/// not on Sparkle types.
@MainActor
protocol UpdateServicing: AnyObject {

    /// Whether a user-initiated update check can currently be started.
    ///
    /// `false` while a check is already in flight, when the updater failed to
    /// start (misconfigured feed / signing key in a dev build), or in builds
    /// where updates are unavailable (App Store).
    var canCheckForUpdates: Bool { get }

    /// User preference: check for updates automatically in the background.
    ///
    /// Persisted by Sparkle in `UserDefaults` (`SUEnableAutomaticChecks`).
    var automaticallyChecksForUpdates: Bool { get set }

    /// Marketing version of the running app (`CFBundleShortVersionString`),
    /// e.g. `"1.4.0 (5)"`.
    var currentVersion: String { get }

    /// Whether in-app updates are supported by this build at all.
    ///
    /// `false` for App Store builds — the UI hides the update controls.
    var updatesSupported: Bool { get }

    /// Begin a user-initiated update check. Shows Sparkle UI on its own.
    func checkForUpdates()
}

// MARK: - Version helper

extension Bundle {

    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `"1.4.0 (5)"`.
    var spacieVersionDisplay: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

// MARK: - NoopUpdateService

/// No-op ``UpdateServicing`` for App Store builds and SwiftUI previews.
@MainActor
final class NoopUpdateService: UpdateServicing {
    var canCheckForUpdates: Bool { false }
    var automaticallyChecksForUpdates: Bool = false
    var currentVersion: String { Bundle.main.spacieVersionDisplay }
    var updatesSupported: Bool { false }
    func checkForUpdates() {}
}

// MARK: - Factory

/// Returns the Sparkle-backed updater in DIRECT builds, a no-op otherwise.
@MainActor
func makeUpdateService() -> UpdateServicing {
    #if DIRECT
    return UpdateService()
    #else
    return NoopUpdateService()
    #endif
}
