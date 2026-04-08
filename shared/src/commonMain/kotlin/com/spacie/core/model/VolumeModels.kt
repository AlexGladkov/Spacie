package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

// MARK: - VolumeType

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeType")
enum class VolumeType {
    INTERNAL,
    EXTERNAL,
    NETWORK,
    DISK_IMAGE;

    val displayName: String
        get() = when (this) {
            INTERNAL -> "Internal"
            EXTERNAL -> "External"
            NETWORK -> "Network"
            DISK_IMAGE -> "Disk Image"
        }
}

// MARK: - FileSystemType

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaFileSystemType")
enum class FileSystemType(val id: String) {
    APFS("apfs"),
    HFS_PLUS("hfs"),
    EXFAT("exfat"),
    FAT32("msdos"),
    NTFS("ntfs"),
    SMB("smbfs"),
    NFS("nfs"),
    UNKNOWN("unknown");

    val displayName: String
        get() = when (this) {
            APFS -> "APFS"
            HFS_PLUS -> "HFS+"
            EXFAT -> "ExFAT"
            FAT32 -> "FAT32"
            NTFS -> "NTFS"
            SMB -> "SMB"
            NFS -> "NFS"
            UNKNOWN -> "Unknown"
        }

    val supportsClones: Boolean get() = this == APFS
}

// MARK: - VolumeInfo

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeInfo")
data class VolumeInfo(
    val id: String,
    val name: String,
    val mountPoint: String,
    val totalCapacity: Long,
    val usedSpace: Long,
    val freeSpace: Long,
    val purgeableSpace: Long,
    val fileSystemType: FileSystemType,
    val volumeType: VolumeType,
    val isReadOnly: Boolean,
    val isBoot: Boolean,
    val uuid: String?
) {
    val availableForImportantUsage: Long
        get() = freeSpace + purgeableSpace

    val usagePercent: Double
        get() {
            if (totalCapacity <= 0L) return 0.0
            return usedSpace.toDouble() / totalCapacity.toDouble()
        }
}

// MARK: - APFSSnapshotInfo

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaAPFSSnapshotInfo")
data class APFSSnapshotInfo(
    val id: String,
    val name: String,
    val date: Long,
    val size: Long?
)
