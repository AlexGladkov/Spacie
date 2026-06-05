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
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.Foundation.NSData
import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSFilePosixPermissions
import platform.Foundation.NSFileSize
import platform.Foundation.NSLocale
import platform.Foundation.NSNumber
import platform.Foundation.NSTimeZone
import platform.Foundation.NSUUID
import platform.Foundation.dateWithTimeIntervalSince1970
import platform.Foundation.timeZoneWithAbbreviation
import platform.Foundation.timeZoneWithName
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
internal class IpaArchiveWriter(
    private val fm: NSFileManager = NSFileManager.defaultManager
) : IpaArchiveWriterApi {

    /**
     * Copy [ipaPath] into a fresh `<archiveDir>/<uuid>/` subdirectory and
     * write a JSON manifest plus optional icon.
     *
     * @throws SpacieError.ArchiveWriteFailed if the IPA copy fails.
     */
    override suspend fun write(ipaPath: String, app: AppInfo, archiveDir: String) {
        // Dispatch the blocking NSFileManager copy + chmod + JSON write
        // onto Dispatchers.Default so a multi-hundred-MB IPA copy does
        // not starve the coroutine pool that also runs the trust-poll
        // loop and the rest of the orchestration flow.
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            writeBlocking(ipaPath, app, archiveDir)
        }
    }

    private fun writeBlocking(ipaPath: String, app: AppInfo, archiveDir: String) {
        ensureDirectory(archiveDir)

        val archiveSubDir = "$archiveDir/${NSUUID().UUIDString}"
        ensureDirectory(archiveSubDir)

        // Sanitize the input path's last component before reusing it as the
        // archive entry's filename. The writer itself does not control how
        // `ipaPath` is produced (e.g. IpaToolClient downloads, future
        // callers); a `..`-bearing or slash-bearing component would otherwise
        // escape `archiveSubDir`. Fall back to `<bundleID>.ipa` when the
        // input is unsafe — matches the Swift adapter's `sanitizeIPAFileName`.
        val ipaFilename = run {
            val raw = ipaPath.substringAfterLast("/").trim()
            val unsafe = raw.isEmpty()
                || raw == ".."
                || raw.startsWith("..")
                || raw.startsWith(".")
                || raw.contains("/")
                || raw.contains("\\")
            if (unsafe) "${app.bundleID}.ipa" else raw
        }
        val destIpaPath = "$archiveSubDir/$ipaFilename"
        copyIpa(from = ipaPath, to = destIpaPath)
        applyOwnerOnlyPermissions(destIpaPath)

        val ipaSize = fileSize(destIpaPath)
        val now = NSDate().timeIntervalSince1970.toLong()
        val metaJson = buildMetadataJson(app, ipaSize, now)
        val metaPath = "$archiveSubDir/metadata.json"
        // Autorelease pool drains the autoreleased NSData wrappers immediately
        // after each writeToFile call. Without it, the temporaries accumulate
        // on the background coroutine thread (no AppKit-managed pool) and
        // hold the byte buffers until the next suspension point.
        // metadata.json is the marker AppArchiveService looks for when
        // listing archives — a silent write failure would copy the IPA but
        // hide the entry from the Library. Check the return value and surface
        // the failure via SpacieError.ArchiveWriteFailed.
        val metaWritten = autoreleasepool {
            metaJson.encodeToByteArray().toNSData().writeToFile(metaPath, atomically = true)
        }
        if (!metaWritten) {
            throw SpacieError.ArchiveWriteFailed(metaPath, "Failed to write metadata.json")
        }

        // Icon is optional — a failed icon write is logged but not fatal.
        app.iconData?.let { iconBytes ->
            val iconPath = "$archiveSubDir/icon.png"
            val iconWritten = autoreleasepool {
                iconBytes.toNSData().writeToFile(iconPath, atomically = true)
            }
            if (!iconWritten) {
                println("[IpaArchiveWriter] icon.png write failed at $iconPath (non-fatal)")
            }
        }
    }

    // -- private --

    private fun ensureDirectory(path: String) {
        memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            val ok = fm.createDirectoryAtPath(
                path,
                withIntermediateDirectories = true,
                attributes = null,
                error = errorPtr.ptr
            )
            // Surface real failures (read-only volume, permission denied)
            // instead of letting them silently propagate as a downstream
            // "copy failed: no such file or directory" with no actionable
            // context.
            if (!ok) {
                val errMsg = errorPtr.value?.localizedDescription
                    ?: "Failed to create archive directory at $path"
                throw SpacieError.ArchiveWriteFailed(path, errMsg)
            }
        }
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
        // chmod failures must surface — if the destination volume (exFAT etc.)
        // does not support POSIX permissions, the archived IPA would be left
        // world-readable, defeating the privacy intent of this directory.
        memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            val ok = fm.setAttributes(
                mapOf<Any?, Any?>(NSFilePosixPermissions to NSNumber(int = 0b110000000)),
                ofItemAtPath = path,
                error = errorPtr.ptr
            )
            if (!ok) {
                val errMsg = errorPtr.value?.localizedDescription
                    ?: "Failed to apply owner-only permissions"
                throw SpacieError.ArchiveWriteFailed(path, errMsg)
            }
        }
    }

    private fun fileSize(path: String): Long = memScoped {
        val errorPtr = alloc<ObjCObjectVar<NSError?>>()
        val attrs = fm.attributesOfItemAtPath(path, error = errorPtr.ptr)
        if (attrs == null) {
            val msg = errorPtr.value?.localizedDescription
                ?: "Failed to stat archived IPA"
            throw SpacieError.ArchiveWriteFailed(path, msg)
        }
        (attrs[NSFileSize] as? NSNumber)?.longLongValue ?: 0L
    }

    private fun buildMetadataJson(app: AppInfo, ipaSize: Long, archivedAt: Long): String {
        // archivedAt is a Unix-epoch seconds Long here; format as ISO 8601
        // to match the Swift `AppArchiveService.listArchivedApps` decoder
        // (which uses `JSONDecoder.dateDecodingStrategy = .iso8601`).
        // Previously the KMP path wrote a raw Long and AppArchiveService
        // silently skipped any KMP-produced entry — invisible archives.
        val isoFormatter = NSDateFormatter().apply {
            dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            // UTC is documented as always available on Apple platforms;
            // GMT is also always available as a defensive fallback.
            // Force-assign (not `?.let { ... }`): without an assignment
            // the formatter would default to the device's local timezone
            // and produce ISO 8601 strings with a local offset, which
            // breaks sort order in the archive Library.
            // UTC is documented as always available on Apple platforms.
            // GMT is the secondary always-available fallback. The triple
            // `?:` chain only meaningfully fires the first branch in
            // practice; declared-only-once if-let guard would be equivalent.
            timeZone = NSTimeZone.timeZoneWithAbbreviation("UTC")
                ?: NSTimeZone.timeZoneWithAbbreviation("GMT")
                ?: NSTimeZone.timeZoneWithName("UTC")
                ?: NSTimeZone.timeZoneWithName("GMT")
                ?: NSTimeZone()
            locale = NSLocale("en_US_POSIX")
        }
        val iso8601 = isoFormatter.stringFromDate(
            NSDate.dateWithTimeIntervalSince1970(archivedAt.toDouble())
        )
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
        sb.append(DeviceServiceHelpers.jsonStringLiteral(iso8601))
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
