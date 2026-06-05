import Foundation
import SpacieKit

// MARK: - SpaVolumeInfo → VolumeInfo

extension SpaVolumeInfo {

    func toSwift() -> VolumeInfo {
        VolumeInfo(
            id: id,
            name: name,
            mountPoint: URL(fileURLWithPath: mountPoint),
            totalCapacity: UInt64(clamping: totalCapacity),
            usedSpace: UInt64(clamping: usedSpace),
            freeSpace: UInt64(clamping: freeSpace),
            purgeableSpace: UInt64(clamping: purgeableSpace),
            fileSystemType: fileSystemType.toSwift(),
            volumeType: volumeType.toSwift(),
            isReadOnly: isReadOnly,
            isBoot: isBoot,
            uuid: uuid
        )
    }
}

// MARK: - SpaVolumeType → VolumeType

extension SpaVolumeType {

    func toSwift() -> VolumeType {
        switch name {
        case "INTERNAL": return .internal
        case "EXTERNAL": return .external
        case "NETWORK":  return .network
        default:         return .disk_image
        }
    }
}

// MARK: - SpaFileSystemType → FileSystemType

extension SpaFileSystemType {

    func toSwift() -> FileSystemType {
        switch name {
        case "APFS":     return .apfs
        case "HFS_PLUS": return .hfsPlus
        case "EXFAT":    return .exfat
        case "FAT32":    return .fat32
        case "NTFS":     return .ntfs
        case "SMB":      return .smb
        case "NFS":      return .nfs
        default:         return .unknown
        }
    }
}
