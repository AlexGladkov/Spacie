@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package com.spacie.core.api

import com.spacie.core.api.internal.DeviceServiceHelpers
import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.Foundation.NSData
import platform.Foundation.NSDate
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSFilePosixPermissions
import platform.Foundation.NSFileSize
import platform.Foundation.NSNumber
import platform.Foundation.NSUUID
import platform.Foundation.dataWithBytes
import platform.Foundation.timeIntervalSince1970
import platform.Foundation.writeToFile

/**
 * Writes an extracted IPA + `metadata.json` to the local archive directory.
 *
 * Extracted from [DeviceServiceImpl] (Sprint 4.5 god-class split) so the file
 * IO + metadata-encoding concerns no longer share a class with the iMobileDevice
 * tool orchestration. The writer is pure platform code (NSFileManager + manual
 * JSON encoding) and depends only on [SpacieError] for failure signalling.
 *
 * Owner-read/write permissions (0600) are applied so other macOS users on the
 * machine cannot read archived IPAs.
 */
class IpaArchiveWriter(
    private val fm: NSFileManager = NSFileManager.defaultManager
) {

    /**
     * Copy [ipaPath] into a fresh `<archiveDir>/<uuid>/` subdirectory and
     * write a JSON manifest plus optional icon.
     *
     * @throws SpacieError.ArchiveWriteFailed if the IPA copy fails.
     */
    fun write(ipaPath: String, app: AppInfo, archiveDir: String) {
        ensureDirectory(archiveDir)

        val archiveSubDir = "$archiveDir/${NSUUID().UUIDString}"
        ensureDirectory(archiveSubDir)

        val ipaFilename = ipaPath.substringAfterLast("/")
        val destIpaPath = "$archiveSubDir/$ipaFilename"
        copyIpa(from = ipaPath, to = destIpaPath)
        applyOwnerOnlyPermissions(destIpaPath)

        val ipaSize = fileSize(destIpaPath)
        val now = NSDate().timeIntervalSince1970.toLong()
        val metaJson = buildMetadataJson(app, ipaSize, now)
        val metaPath = "$archiveSubDir/metadata.json"
        metaJson.encodeToByteArray().toNSData().writeToFile(metaPath, atomically = true)

        app.iconData?.let { iconBytes ->
            val iconPath = "$archiveSubDir/icon.png"
            iconBytes.toNSData().writeToFile(iconPath, atomically = true)
        }
    }

    // -- private --

    private fun ensureDirectory(path: String) {
        fm.createDirectoryAtPath(
            path,
            withIntermediateDirectories = true,
            attributes = null,
            error = null
        )
    }

    private fun copyIpa(from: String, to: String) {
        memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            val copied = fm.copyItemAtPath(from, toPath = to, error = errorPtr.ptr)
            if (!copied) {
                val errMsg = errorPtr.value?.localizedDescription ?: "Unknown error"
                throw SpacieError.ArchiveWriteFailed(to, errMsg)
            }
        }
    }

    private fun applyOwnerOnlyPermissions(path: String) {
        // 0b110000000 == 0600 — owner read+write, no group/other access.
        fm.setAttributes(
            mapOf<Any?, Any?>(NSFilePosixPermissions to NSNumber(int = 0b110000000)),
            ofItemAtPath = path,
            error = null
        )
    }

    private fun fileSize(path: String): Long = memScoped {
        val errorPtr = alloc<ObjCObjectVar<NSError?>>()
        val attrs = fm.attributesOfItemAtPath(path, error = errorPtr.ptr)
        (attrs?.get(NSFileSize) as? NSNumber)?.longLongValue ?: 0L
    }

    private fun buildMetadataJson(app: AppInfo, ipaSize: Long, archivedAt: Long): String {
        val sb = StringBuilder()
        sb.append("{")
        sb.append("\"bundleID\":")
        sb.append(DeviceServiceHelpers.jsonStringLiteral(app.bundleID))
        sb.append(",\"displayName\":")
        sb.append(DeviceServiceHelpers.jsonStringLiteral(app.displayName))
        sb.append(",\"version\":")
        sb.append(DeviceServiceHelpers.jsonStringLiteral(app.version))
        sb.append(",\"shortVersion\":")
        sb.append(DeviceServiceHelpers.jsonStringLiteral(app.shortVersion))
        sb.append(",\"ipaSize\":")
        sb.append(ipaSize.toString())
        sb.append(",\"archivedAt\":")
        sb.append(archivedAt.toString())
        sb.append("}")
        return sb.toString()
    }

    private fun ByteArray.toNSData(): NSData {
        if (isEmpty()) return NSData()
        return usePinned { pin ->
            NSData.dataWithBytes(pin.addressOf(0), length = size.toULong()) ?: NSData()
        }
    }
}
