import Foundation
import AppKit
import SpacieKit

// MARK: - VolumeManager

/// Discovers and monitors mounted volumes on the system.
///
/// Delegates volume enumeration to KMP `SpaVolumeManagerApi`.
/// Keeps NSWorkspace notifications in Swift to trigger refreshes.
/// `listAPFSSnapshots` remains Swift-only (diskutil parsing).
///
/// `@MainActor` isolated: all mutations to `volumes` happen on the main thread,
/// matching the actor SwiftUI reads from. The NSWorkspace observers post on
/// `.main` queue so the `refresh()` call inside is already main-isolated.
@MainActor
@Observable
final class VolumeManager {

    // MARK: - Singleton

    static let shared = VolumeManager()

    // MARK: - Published State

    private(set) var volumes: [VolumeInfo] = []

    // MARK: - KMP

    private let kmpManager: any SpaVolumeManagerApi = SpaSpacieFactory.shared.createVolumeManager()

    // MARK: - Private

    /// `nonisolated(unsafe)` because we need to read these in `deinit` (which
    /// is nonisolated on Swift 6 `@MainActor` classes). The properties are
    /// only ever written on the main actor (from `startMonitoring` /
    /// `stopMonitoring`), and `deinit` only fires after the last reference is
    /// released — so there is no concurrent writer to race against.
    // ObservationIgnored: these are infrastructure, not UI state.
    // nonisolated(unsafe): needed so the nonisolated `deinit` can read them
    // for one-shot observer cleanup. They are only mutated on the main actor
    // (start/stopMonitoring), and deinit only runs after the last reference
    // is dropped — so no concurrent writer exists at cleanup time.
    @ObservationIgnored
    nonisolated(unsafe) private var mountObserver: NSObjectProtocol?
    @ObservationIgnored
    nonisolated(unsafe) private var unmountObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        refresh()
    }

    // MARK: - Public API

    /// Reloads the list of mounted volumes from KMP.
    func refresh() {
        kmpManager.refresh()
        let raw = kmpManager.volumes.value
        let kmpVolumes = (raw as? NSArray)?.compactMap { $0 as? SpaVolumeInfo } ?? []
        volumes = kmpVolumes.map { $0.toSwift() }
    }

    /// Begins observing NSWorkspace mount and unmount notifications.
    /// Note: KMP monitoring is NOT started — Swift handles notifications
    /// and triggers `refresh()` which re-reads KMP data. Starting both
    /// would double-subscribe to the same NSWorkspace notifications.
    func startMonitoring() {
        stopMonitoring()

        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Stops observing mount/unmount notifications.
    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        if let observer = mountObserver {
            center.removeObserver(observer)
            mountObserver = nil
        }
        if let observer = unmountObserver {
            center.removeObserver(observer)
            unmountObserver = nil
        }
    }

    /// Attempts to list APFS snapshots for the given volume UUID.
    /// Remains in Swift — KMP does not provide diskutil parsing.
    func listAPFSSnapshots(volumeUUID: String) async -> [APFSSnapshotInfo] {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["apfs", "listSnapshots", volumeUUID]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: [])
                    return
                }

                let snapshots = Self.parseSnapshots(output)
                continuation.resume(returning: snapshots)
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    // MARK: - Private Helpers

    private static func parseSnapshots(_ output: String) -> [APFSSnapshotInfo] {
        var snapshots: [APFSSnapshotInfo] = []
        let lines = output.components(separatedBy: .newlines)

        var currentName: String?
        var currentUUID: String?
        var currentDate: Date?

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Snapshot Name:") {
                if let name = currentName {
                    let id = currentUUID ?? UUID().uuidString
                    snapshots.append(APFSSnapshotInfo(
                        id: id,
                        name: name,
                        date: currentDate ?? Date.distantPast,
                        size: nil
                    ))
                }
                currentName = String(trimmed.dropFirst("Snapshot Name:".count)).trimmingCharacters(in: .whitespaces)
                currentUUID = nil
                currentDate = nil
            } else if trimmed.hasPrefix("Snapshot UUID:") {
                currentUUID = String(trimmed.dropFirst("Snapshot UUID:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Snapshot Date:") {
                let dateString = String(trimmed.dropFirst("Snapshot Date:".count)).trimmingCharacters(in: .whitespaces)
                currentDate = dateFormatter.date(from: dateString)
            }
        }

        if let name = currentName {
            let id = currentUUID ?? UUID().uuidString
            snapshots.append(APFSSnapshotInfo(
                id: id,
                name: name,
                date: currentDate ?? Date.distantPast,
                size: nil
            ))
        }

        return snapshots
    }

    deinit {
        // Synchronous, thread-safe direct removal: NotificationCenter.removeObserver
        // is callable from any thread, and these stored properties are only
        // mutated on the main actor — so reading them at deinit-time is safe
        // because no one else holds a reference (deinit implies last reference).
        let center = NSWorkspace.shared.notificationCenter
        if let observer = mountObserver { center.removeObserver(observer) }
        if let observer = unmountObserver { center.removeObserver(observer) }
    }
}
