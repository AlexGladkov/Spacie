@file:OptIn(ExperimentalForeignApi::class)

package com.spacie.core.api

import com.spacie.core.flow.CommonStateFlow
import com.spacie.core.flow.asCommonStateFlow
import com.spacie.core.model.FileSystemType
import com.spacie.core.model.VolumeInfo
import com.spacie.core.model.VolumeType
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import kotlinx.coroutines.flow.MutableStateFlow
import platform.AppKit.NSWorkspace
import platform.AppKit.NSWorkspaceDidMountNotification
import platform.AppKit.NSWorkspaceDidUnmountNotification
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSNumber
import platform.Foundation.NSOperationQueue
import platform.Foundation.NSURL
import platform.Foundation.NSURLVolumeAvailableCapacityForImportantUsageKey
import platform.Foundation.NSURLVolumeAvailableCapacityKey
import platform.Foundation.NSURLVolumeIsInternalKey
import platform.Foundation.NSURLVolumeIsLocalKey
import platform.Foundation.NSURLVolumeIsReadOnlyKey
import platform.Foundation.NSURLVolumeLocalizedFormatDescriptionKey
import platform.Foundation.NSURLVolumeNameKey
import platform.Foundation.NSURLVolumeTotalCapacityKey
import platform.Foundation.NSURLVolumeUUIDStringKey
import platform.Foundation.NSVolumeEnumerationSkipHiddenVolumes
import platform.darwin.NSObjectProtocol
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeManagerImpl")
class VolumeManagerImpl : VolumeManagerApi {

    private val _volumes = MutableStateFlow<List<VolumeInfo>>(emptyList())
    override val volumes: CommonStateFlow<List<VolumeInfo>> = _volumes.asCommonStateFlow()

    private var mountObserver: NSObjectProtocol? = null
    private var unmountObserver: NSObjectProtocol? = null

    init {
        refresh()
    }

    override fun refresh() {
        val fm = NSFileManager.defaultManager

        val resourceKeys = listOf(
            NSURLVolumeNameKey,
            NSURLVolumeTotalCapacityKey,
            NSURLVolumeAvailableCapacityKey,
            NSURLVolumeAvailableCapacityForImportantUsageKey,
            NSURLVolumeIsReadOnlyKey,
            NSURLVolumeUUIDStringKey,
            NSURLVolumeIsInternalKey,
            NSURLVolumeIsLocalKey,
            NSURLVolumeLocalizedFormatDescriptionKey
        )

        @Suppress("UNCHECKED_CAST")
        val urls = fm.mountedVolumeURLsIncludingResourceValuesForKeys(
            propertyKeys = resourceKeys,
            options = NSVolumeEnumerationSkipHiddenVolumes
        ) as? List<NSURL> ?: emptyList()

        val infos = urls
            .mapNotNull { url -> buildVolumeInfo(url) }
            .sortedWith(
                compareByDescending<VolumeInfo> { it.isBoot }
                    .thenBy { volumeTypePriority(it.volumeType) }
                    .thenBy { it.name }
            )

        _volumes.value = infos
    }

    override fun startMonitoring() {
        stopMonitoring()
        val center = NSWorkspace.sharedWorkspace.notificationCenter

        mountObserver = center.addObserverForName(
            name = NSWorkspaceDidMountNotification,
            `object` = null,
            queue = NSOperationQueue.mainQueue,
            usingBlock = { _ -> refresh() }
        )
        unmountObserver = center.addObserverForName(
            name = NSWorkspaceDidUnmountNotification,
            `object` = null,
            queue = NSOperationQueue.mainQueue,
            usingBlock = { _ -> refresh() }
        )
    }

    override fun stopMonitoring() {
        val center = NSWorkspace.sharedWorkspace.notificationCenter
        mountObserver?.let { center.removeObserver(it) }
        unmountObserver?.let { center.removeObserver(it) }
        mountObserver = null
        unmountObserver = null
    }

    // -- Private helpers --

    private fun buildVolumeInfo(url: NSURL): VolumeInfo? {
        val resourceKeys = listOf(
            NSURLVolumeNameKey,
            NSURLVolumeTotalCapacityKey,
            NSURLVolumeAvailableCapacityKey,
            NSURLVolumeAvailableCapacityForImportantUsageKey,
            NSURLVolumeIsReadOnlyKey,
            NSURLVolumeUUIDStringKey,
            NSURLVolumeIsInternalKey,
            NSURLVolumeIsLocalKey,
            NSURLVolumeLocalizedFormatDescriptionKey
        )

        val resources: Map<Any?, Any?> = memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            url.resourceValuesForKeys(resourceKeys, errorPtr.ptr)
        } ?: return null

        val name = (resources[NSURLVolumeNameKey] as? String)
            ?: (url.lastPathComponent ?: "Unknown")

        val totalCapacity =
            (resources[NSURLVolumeTotalCapacityKey] as? NSNumber)?.longLongValue ?: 0L
        val availableCapacity =
            (resources[NSURLVolumeAvailableCapacityKey] as? NSNumber)?.longLongValue ?: 0L
        val availableForImportant =
            (resources[NSURLVolumeAvailableCapacityForImportantUsageKey] as? NSNumber)
                ?.longLongValue ?: 0L
        val isReadOnly =
            (resources[NSURLVolumeIsReadOnlyKey] as? NSNumber)?.boolValue ?: false
        val uuid =
            resources[NSURLVolumeUUIDStringKey] as? String
        val isInternal =
            (resources[NSURLVolumeIsInternalKey] as? NSNumber)?.boolValue ?: true
        val isLocal =
            (resources[NSURLVolumeIsLocalKey] as? NSNumber)?.boolValue ?: true
        val localizedFormatDesc =
            resources[NSURLVolumeLocalizedFormatDescriptionKey] as? String

        val mountPath = url.path ?: return null
        val usedSpace =
            if (totalCapacity > availableCapacity) totalCapacity - availableCapacity else 0L
        val purgeableSpace =
            if (availableForImportant > availableCapacity) availableForImportant - availableCapacity else 0L
        val isBoot = mountPath == "/"

        val volumeType = determineVolumeType(isInternal, isLocal, mountPath)
        val fsType = determineFileSystemType(localizedFormatDesc)

        return VolumeInfo(
            id = uuid ?: mountPath,
            name = name,
            mountPoint = mountPath,
            totalCapacity = totalCapacity,
            usedSpace = usedSpace,
            freeSpace = availableCapacity,
            purgeableSpace = purgeableSpace,
            fileSystemType = fsType,
            volumeType = volumeType,
            isReadOnly = isReadOnly,
            isBoot = isBoot,
            uuid = uuid
        )
    }

    private fun determineVolumeType(
        isInternal: Boolean,
        isLocal: Boolean,
        mountPath: String
    ): VolumeType {
        if (!isLocal) return VolumeType.NETWORK
        if (mountPath.contains("/DiskImages/") || mountPath.endsWith(".dmg")) {
            return VolumeType.DISK_IMAGE
        }
        return if (isInternal) VolumeType.INTERNAL else VolumeType.EXTERNAL
    }

    /**
     * Determine [FileSystemType] from the localized format description.
     *
     * macOS returns strings like:
     * - "APFS" / "APFS (Encrypted)" / "APFS (Case-sensitive)"
     * - "Mac OS Extended" / "Mac OS Extended (Journaled)"
     * - "ExFAT"
     * - "MS-DOS (FAT32)"
     * - "NTFS"
     * - "SMB" / "NFS"
     */
    private fun determineFileSystemType(localizedDescription: String?): FileSystemType {
        if (localizedDescription == null) return FileSystemType.UNKNOWN
        val desc = localizedDescription.lowercase()
        return when {
            desc.startsWith("apfs") -> FileSystemType.APFS
            desc.contains("mac os extended") || desc.contains("hfs") -> FileSystemType.HFS_PLUS
            desc.contains("exfat") -> FileSystemType.EXFAT
            desc.contains("fat32") || desc.contains("fat16") || desc.contains("ms-dos") -> FileSystemType.FAT32
            desc.contains("ntfs") -> FileSystemType.NTFS
            desc.contains("smb") -> FileSystemType.SMB
            desc.contains("nfs") -> FileSystemType.NFS
            else -> FileSystemType.UNKNOWN
        }
    }

    private fun volumeTypePriority(type: VolumeType): Int = when (type) {
        VolumeType.INTERNAL -> 0
        VolumeType.EXTERNAL -> 1
        VolumeType.DISK_IMAGE -> 2
        VolumeType.NETWORK -> 3
    }
}
