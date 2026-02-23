import Foundation

// MARK: - VolumeType

enum VolumeType: Sendable {
    case `internal`
    case external
    case network
    case disk_image

    var displayName: String {
        switch self {
        case .internal: "Internal"
        case .external: "External"
        case .network: "Network"
        case .disk_image: "Disk Image"
        }
    }
}

// MARK: - FileSystemType

enum FileSystemType: String, Sendable {
    case apfs = "apfs"
    case hfsPlus = "hfs"
    case exfat = "exfat"
    case fat32 = "msdos"
    case ntfs = "ntfs"
    case smb = "smbfs"
    case nfs = "nfs"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .apfs: "APFS"
        case .hfsPlus: "HFS+"
        case .exfat: "ExFAT"
        case .fat32: "FAT32"
        case .ntfs: "NTFS"
        case .smb: "SMB"
        case .nfs: "NFS"
        case .unknown: "Unknown"
        }
    }

    var supportsClones: Bool {
        self == .apfs
    }
}

// MARK: - VolumeInfo

struct VolumeInfo: Identifiable, Sendable, Hashable {
    let id: String // UUID or mount point
    let name: String
    let mountPoint: URL
    let totalCapacity: UInt64
    let usedSpace: UInt64
    let freeSpace: UInt64
    let purgeableSpace: UInt64
    let fileSystemType: FileSystemType
    let volumeType: VolumeType
    let isReadOnly: Bool
    let isBoot: Bool
    let uuid: String?

    var availableForImportantUsage: UInt64 {
        freeSpace + purgeableSpace
    }

    var usagePercent: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedSpace) / Double(totalCapacity)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: VolumeInfo, rhs: VolumeInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - APFSSnapshotInfo

struct APFSSnapshotInfo: Identifiable, Sendable {
    let id: String
    let name: String
    let date: Date
    let size: UInt64?
}
