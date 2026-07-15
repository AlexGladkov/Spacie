// MARK: - UpdateService
// Sparkle-backed implementation of in-app auto-update (DIRECT builds only).
// macOS 15+, Swift 6

#if DIRECT

import AppKit
import OSLog
import Sparkle

// MARK: - UpdateService

/// Production ``UpdateServicing`` implementation wrapping Sparkle's `SPUUpdater`.
///
/// Uses `SPUUpdater` + `SPUStandardUserDriver` directly (rather than
/// `SPUStandardUpdaterController`) so startup errors are surfaced through a
/// `throws` call we can log and swallow — instead of Sparkle popping a modal
/// alert on every launch when the feed URL or public EdDSA key is not yet
/// configured (e.g. locally signed dev builds).
///
/// Configuration lives in `Info.plist`:
/// - `SUFeedURL` — appcast location (GitHub Pages)
/// - `SUPublicEDKey` — EdDSA public key that verifies downloaded updates
/// - `SUEnableAutomaticChecks` / `SUScheduledCheckInterval`
@MainActor
final class UpdateService: NSObject, UpdateServicing {

    private let updater: SPUUpdater
    private let userDriver: SPUStandardUserDriver
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.spacie.app",
        category: "updates"
    )

    override init() {
        let hostBundle = Bundle.main
        userDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: nil
        )
        super.init()

        do {
            try updater.start()
        } catch {
            // Non-fatal: a dev build without a valid SUPublicEDKey / SUFeedURL
            // simply cannot check for updates. Log and continue — the menu item
            // and settings button reflect this via `canCheckForUpdates`.
            logger.error("Sparkle updater failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UpdateServicing

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var currentVersion: String { Bundle.main.spacieVersionDisplay }

    var updatesSupported: Bool { true }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

#endif
