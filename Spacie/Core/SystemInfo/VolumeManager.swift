import Foundation
import AppKit
import SpacieKit

// MARK: - VolumeManaging

/// Abstraction over mounted-volume discovery so views/tests can mock the
/// volume list and APFS snapshots without touching the filesystem or KMP.
///
/// Per-member `@MainActor` isolation lets the type conform without forcing
/// the protocol itself main-actor, which is required by `EnvironmentKey`.
protocol VolumeManaging: AnyObject, Sendable {
    @MainActor var volumes: [VolumeInfo] { get }
    @MainActor func refresh()
    @MainActor func startMonitoring()
    @MainActor func stopMonitoring()
    @MainActor func listAPFSSnapshots(volumeUUID: String) async -> [APFSSnapshotInfo]
}

// MARK: - VolumeManager

/// Discovers and monitors mounted volumes via KMP `SpaVolumeManagerApi`.
/// NSWorkspace notifications drive refreshes (KMP monitoring is intentionally
/// not started — running both would double-fire).
@MainActor
@Observable
final class VolumeManager: VolumeManaging {

    // MARK: - Singleton

    /// Convenience singleton used by legacy call sites. New code should inject
    /// `any VolumeManaging` through the SwiftUI environment instead.
    static let shared = VolumeManager()

    // MARK: - Published State

    private(set) var volumes: [VolumeInfo] = []

    // MARK: - KMP

    private let kmpManager: any SpaVolumeManagerApi

    // MARK: - Private

    // Regular MainActor-isolated; touched from `isolated deinit` (Swift 6.1+).
    @ObservationIgnored
    private var mountObserver: NSObjectProtocol?
    @ObservationIgnored
    private var unmountObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(
        kmpManager: any SpaVolumeManagerApi = SpaSpacieFactory.shared.createVolumeManager()
    ) {
        self.kmpManager = kmpManager
        refresh()
    }

    // MARK: - Public API

    func refresh() {
        kmpManager.refresh()
        let raw = kmpManager.volumes.value
        let kmpVolumes = (raw as? NSArray)?.compactMap { $0 as? SpaVolumeInfo } ?? []
        volumes = kmpVolumes.map { $0.toSwift() }
    }

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
    /// Stays in Swift — KMP does not provide diskutil parsing.
    func listAPFSSnapshots(volumeUUID: String) async -> [APFSSnapshotInfo] {
        // Offload to a detached task: Process.run + waitUntilExit + the
        // subsequent readDataToEndOfFile all block the caller's thread. When
        // invoked from a MainActor context (Settings UI / dependency checks),
        // this previously froze the UI for the duration of `diskutil apfs
        // listSnapshots`.
        await Task.detached(priority: .userInitiated) {
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
                    return [APFSSnapshotInfo]()
                }
                return Self.parseSnapshots(output)
            } catch {
                return [APFSSnapshotInfo]()
            }
        }.value
    }

    // MARK: - Private Helpers

    nonisolated private static func parseSnapshots(_ output: String) -> [APFSSnapshotInfo] {
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

    isolated deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let observer = mountObserver { center.removeObserver(observer) }
        if let observer = unmountObserver { center.removeObserver(observer) }
    }
}

// MARK: - MockVolumeManager

#if DEBUG
@MainActor
@Observable
final class MockVolumeManager: VolumeManaging {

    var volumes: [VolumeInfo]
    var snapshotsByUUID: [String: [APFSSnapshotInfo]] = [:]

    private(set) var refreshCallCount = 0
    private(set) var isMonitoring = false

    init(volumes: [VolumeInfo] = []) {
        self.volumes = volumes
    }

    func refresh() { refreshCallCount += 1 }
    func startMonitoring() { isMonitoring = true }
    func stopMonitoring() { isMonitoring = false }

    func listAPFSSnapshots(volumeUUID: String) async -> [APFSSnapshotInfo] {
        snapshotsByUUID[volumeUUID] ?? []
    }
}
#endif
