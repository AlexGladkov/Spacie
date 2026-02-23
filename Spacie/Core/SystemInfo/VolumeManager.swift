import Foundation
import AppKit

// MARK: - VolumeManager

/// Discovers and monitors mounted volumes on the system.
///
/// Uses `FileManager.mountedVolumeURLs` to enumerate available volumes,
/// enriching each with capacity, file system type, and other metadata
/// from URL resource values and `statfs`. Listens for mount/unmount
/// events via `NSWorkspace` notifications and refreshes the volume list
/// automatically.
///
/// ## Usage
/// ```swift
/// let manager = VolumeManager.shared
/// manager.startMonitoring()
/// for volume in manager.volumes { ... }
/// ```
@Observable
final class VolumeManager: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = VolumeManager()

    // MARK: - Published State

    /// All currently mounted volumes discovered on the system.
    private(set) var volumes: [VolumeInfo] = []

    // MARK: - Private

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {
        refresh()
    }

    // MARK: - Public API

    /// Reloads the list of mounted volumes from the system.
    ///
    /// Queries `FileManager.mountedVolumeURLs` with a comprehensive set of
    /// resource keys, then builds a ``VolumeInfo`` for each discovered volume.
    /// Skips hidden volumes that are typically not user-relevant (e.g., recovery partitions).
    func refresh() {
        let resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsReadOnlyKey,
            .volumeUUIDStringKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey,
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) else {
            volumes = []
            return
        }

        volumes = urls.compactMap { url in
            buildVolumeInfo(from: url, resourceKeys: resourceKeys)
        }
        .sorted { lhs, rhs in
            // Boot volume first, then internal, then external, then network
            if lhs.isBoot != rhs.isBoot { return lhs.isBoot }
            let lhsPriority = volumeTypePriority(lhs.volumeType)
            let rhsPriority = volumeTypePriority(rhs.volumeType)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// Begins observing NSWorkspace mount and unmount notifications.
    ///
    /// When a volume is mounted or unmounted, the volume list is
    /// refreshed automatically on the main actor.
    func startMonitoring() {
        stopMonitoring()

        let workspace = NSWorkspace.shared
        let center = workspace.notificationCenter

        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }

        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
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
    ///
    /// Runs `diskutil apfs listSnapshots` and parses the textual output
    /// to extract snapshot names, dates, and sizes. Returns an empty array
    /// if the command fails or the volume is not APFS.
    ///
    /// - Parameter volumeUUID: The UUID of the APFS volume.
    /// - Returns: An array of ``APFSSnapshotInfo`` for the volume.
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

    /// Constructs a ``VolumeInfo`` from a volume URL and its resource values.
    private func buildVolumeInfo(from url: URL, resourceKeys: Set<URLResourceKey>) -> VolumeInfo? {
        guard let resources = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }

        let name = resources.volumeName ?? url.lastPathComponent
        let totalCapacity = UInt64(resources.volumeTotalCapacity ?? 0)
        let availableCapacity = UInt64(resources.volumeAvailableCapacity ?? 0)
        let availableForImportant = UInt64(truncatingIfNeeded: resources.volumeAvailableCapacityForImportantUsage ?? 0)
        let isReadOnly = resources.volumeIsReadOnly ?? false
        let uuid = resources.volumeUUIDString
        let isInternal = resources.volumeIsInternal ?? true
        let isLocal = resources.volumeIsLocal ?? true

        let usedSpace = totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
        let purgeableSpace = availableForImportant > availableCapacity ? availableForImportant - availableCapacity : 0

        let mountPath = url.path
        let isBoot = mountPath == "/"

        let volumeType = determineVolumeType(isInternal: isInternal, isLocal: isLocal, mountPath: mountPath)
        let fsType = determineFileSystemType(mountPath: mountPath)

        let volumeId = uuid ?? mountPath

        return VolumeInfo(
            id: volumeId,
            name: name,
            mountPoint: url,
            totalCapacity: totalCapacity,
            usedSpace: usedSpace,
            freeSpace: availableCapacity,
            purgeableSpace: purgeableSpace,
            fileSystemType: fsType,
            volumeType: volumeType,
            isReadOnly: isReadOnly,
            isBoot: isBoot,
            uuid: uuid
        )
    }

    /// Determines the volume type based on system resource values.
    private func determineVolumeType(isInternal: Bool, isLocal: Bool, mountPath: String) -> VolumeType {
        if !isLocal {
            return .network
        }
        if mountPath.contains("/DiskImages/") || mountPath.hasSuffix(".dmg") {
            return .disk_image
        }
        return isInternal ? .internal : .external
    }

    /// Determines the file system type by calling `statfs` on the mount path.
    private func determineFileSystemType(mountPath: String) -> FileSystemType {
        var stat = statfs()
        guard statfs(mountPath, &stat) == 0 else { return .unknown }

        let fsTypeName = withUnsafePointer(to: &stat.f_fstypename) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { cStr in
                String(cString: cStr)
            }
        }

        return FileSystemType(rawValue: fsTypeName) ?? .unknown
    }

    /// Returns a sort-priority integer for volume types (lower = higher priority).
    private func volumeTypePriority(_ type: VolumeType) -> Int {
        switch type {
        case .internal: 0
        case .external: 1
        case .disk_image: 2
        case .network: 3
        }
    }

    /// Parses the output of `diskutil apfs listSnapshots` into snapshot models.
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
                // Save previous snapshot if exists
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

        // Capture the last snapshot
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
        stopMonitoring()
    }
}
