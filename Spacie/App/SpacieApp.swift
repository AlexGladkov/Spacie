import SwiftUI
import Combine

// MARK: - SpacieApp

/// Main entry point for the Spacie disk analyzer application.
///
/// Configures a single ``WindowGroup`` with native macOS tab support,
/// registers core services into the SwiftUI environment, and defines
/// menu bar commands for navigation, visualization switching, and scanning.
///
/// Observes `NSApplication.willTerminateNotification` to persist the current
/// scan cache on app exit, ensuring the next launch can restore instantly.
@main
struct SpacieApp: App {

    // MARK: - Services

    @State private var volumeManager = VolumeManager.shared
    @State private var permissionManager = PermissionManager()

    // MARK: - Body

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(volumeManager)
                .environment(permissionManager)
                .onAppear {
                    permissionManager.checkFullDiskAccess()
                    volumeManager.refresh()
                    volumeManager.startMonitoring()
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
                ) { _ in
                    // Step 10: Save current tree to cache on app termination.
                    // We post a notification that ContentView's AppViewModel
                    // can observe to trigger its saveCurrentStateToCache().
                    NotificationCenter.default.post(
                        name: .spacieSaveCacheOnTerminate,
                        object: nil
                    )
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            spacieFileCommands
            spacieViewCommands
            spacieScanCommands
            spacieGoCommands
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - File Commands

    private var spacieFileCommands: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Tab") {
                NotificationCenter.default.post(name: .spacieNewTab, object: nil)
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                NotificationCenter.default.post(name: .spacieCloseTab, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }

    // MARK: - View Commands

    private var spacieViewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Sunburst") {
                NotificationCenter.default.post(name: .spacieSetVisualization, object: VisualizationMode.sunburst)
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("Treemap") {
                NotificationCenter.default.post(name: .spacieSetVisualization, object: VisualizationMode.treemap)
            }
            .keyboardShortcut("2", modifiers: .command)
        }
    }

    // MARK: - Scan Commands

    private var spacieScanCommands: some Commands {
        CommandMenu("Scan") {
            Button("Rescan") {
                NotificationCenter.default.post(name: .spacieRescan, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)
        }
    }

    // MARK: - Go Commands

    private var spacieGoCommands: some Commands {
        CommandMenu("Go") {
            Button("Back") {
                NotificationCenter.default.post(name: .spacieNavigateBack, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)

            Button("Forward") {
                NotificationCenter.default.post(name: .spacieNavigateForward, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)

            Button("Parent Directory") {
                NotificationCenter.default.post(name: .spacieNavigateParent, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Divider()

            Button("Go to Folder...") {
                NotificationCenter.default.post(name: .spacieGoToFolder, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let spacieNewTab = Notification.Name("spacieNewTab")
    static let spacieCloseTab = Notification.Name("spacieCloseTab")
    static let spacieSetVisualization = Notification.Name("spacieSetVisualization")
    static let spacieRescan = Notification.Name("spacieRescan")
    static let spacieNavigateBack = Notification.Name("spacieNavigateBack")
    static let spacieNavigateForward = Notification.Name("spacieNavigateForward")
    static let spacieNavigateParent = Notification.Name("spacieNavigateParent")
    static let spacieGoToFolder = Notification.Name("spacieGoToFolder")
    /// Posted by ``SpacieApp`` when the application is about to terminate.
    /// ``AppViewModel`` observes this to persist the current scan cache.
    static let spacieSaveCacheOnTerminate = Notification.Name("spacieSaveCacheOnTerminate")
}
