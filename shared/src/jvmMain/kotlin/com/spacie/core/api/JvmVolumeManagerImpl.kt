package com.spacie.core.api

import com.spacie.core.flow.CommonStateFlow
import com.spacie.core.flow.asCommonStateFlow
import com.spacie.core.model.FileSystemType
import com.spacie.core.model.VolumeInfo
import com.spacie.core.model.VolumeType
import kotlinx.coroutines.flow.MutableStateFlow
import java.io.File
import java.nio.file.FileSystems

/**
 * JVM implementation of [VolumeManagerApi].
 *
 * Enumerates file stores via [java.nio.file.FileSystem.getFileStores].
 * Live monitoring is not implemented (no cross-platform FSEvents equivalent
 * in the JDK without additional libraries); [startMonitoring] performs a
 * single [refresh] call.
 */
class JvmVolumeManagerImpl : VolumeManagerApi {

    private val _volumes = MutableStateFlow<List<VolumeInfo>>(emptyList())
    override val volumes: CommonStateFlow<List<VolumeInfo>> = _volumes.asCommonStateFlow()

    override fun startMonitoring() {
        refresh()
    }

    override fun stopMonitoring() {
        // No background monitoring to stop on the basic JVM target
    }

    override fun refresh() {
        val fileSystem = FileSystems.getDefault()
        val infos = fileSystem.fileStores.mapNotNull { store ->
            try {
                val totalSpace = store.totalSpace
                val usableSpace = store.usableSpace
                val usedSpace = if (totalSpace > usableSpace) totalSpace - usableSpace else 0L
                // getFileStores().toString() returns "<name> (<type>)" on most JVMs;
                // strip the type suffix to get a usable mount point approximation.
                val mountPoint = store.toString().substringBefore(" (").trim()

                VolumeInfo(
                    id = mountPoint,
                    name = store.name().ifEmpty { mountPoint },
                    mountPoint = mountPoint,
                    totalCapacity = totalSpace,
                    usedSpace = usedSpace,
                    freeSpace = usableSpace,
                    purgeableSpace = 0L,
                    fileSystemType = mapFileSystemType(store.type()),
                    volumeType = resolveVolumeType(mountPoint),
                    isReadOnly = !File(mountPoint).canWrite(),
                    isBoot = isBootVolume(mountPoint),
                    uuid = null
                )
            } catch (_: Exception) {
                null
            }
        }
        _volumes.value = infos
    }

    // -- Private helpers --

    private fun mapFileSystemType(type: String): FileSystemType {
        return when (type.uppercase().trim()) {
            "NTFS" -> FileSystemType.NTFS
            "FAT32", "FAT", "VFAT" -> FileSystemType.FAT32
            "EXFAT" -> FileSystemType.EXFAT
            "APFS" -> FileSystemType.APFS
            "HFS", "HFSPLUS", "HFS+" -> FileSystemType.HFS_PLUS
            "SMB", "SMBFS", "CIFS" -> FileSystemType.SMB
            "NFS" -> FileSystemType.NFS
            else -> FileSystemType.UNKNOWN
        }
    }

    private fun resolveVolumeType(mountPoint: String): VolumeType {
        val os = System.getProperty("os.name").orEmpty().lowercase()
        return when {
            // Windows: C: is typically the boot/internal drive
            os.contains("win") && mountPoint.uppercase().startsWith("C:") -> VolumeType.INTERNAL
            // Unix-like: root mount is internal
            mountPoint == "/" -> VolumeType.INTERNAL
            else -> VolumeType.EXTERNAL
        }
    }

    private fun isBootVolume(mountPoint: String): Boolean {
        val os = System.getProperty("os.name").orEmpty().lowercase()
        return when {
            os.contains("win") -> mountPoint.uppercase().startsWith("C:")
            else -> mountPoint == "/"
        }
    }
}
