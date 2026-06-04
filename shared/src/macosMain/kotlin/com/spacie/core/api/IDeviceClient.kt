@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package com.spacie.core.api

import com.spacie.core.api.internal.DeviceServiceHelpers
import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TrustState
import com.spacie.core.platform.ProcessRunnerApi
import com.spacie.core.platform.pathExists
import com.spacie.core.validation.InputValidator
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSNumber
import platform.Foundation.NSPropertyListMutableContainersAndLeaves
import platform.Foundation.NSPropertyListSerialization
import platform.Foundation.dataWithBytes

/**
 * Wraps the libimobiledevice CLI tools (`idevice_id`, `ideviceinfo`,
 * `idevicepair`, `ideviceinstaller`) used to enumerate connected iPhones,
 * inspect their metadata, validate the pairing trust state, list installed
 * apps, and install an IPA.
 *
 * Extracted from `DeviceServiceImpl` (Sprint 4.5 god-class split). The plist
 * (`ideviceinstaller list --xml`) parsing is also encapsulated here because it
 * is the only consumer of `NSPropertyListSerialization` in the codebase.
 */
internal class IDeviceClient(
    private val runner: ProcessRunnerApi,
    private val paths: ToolPaths,
) {

    /** `idevice_id -l` then `ideviceinfo` for each UDID. */
    suspend fun listDevices(): List<DeviceInfo> {
        val ideviceId = paths.require("idevice_id")
        val ideviceInfo = paths.require("ideviceinfo")

        val result = runner.run(
            executablePath = ideviceId,
            arguments = listOf("-l"),
            timeoutSeconds = 10.0
        )

        val udids = result.stdout.decodeToString()
            .split("\n")
            .map { it.trim() }
            .filter { it.isNotEmpty() }

        return udids.mapNotNull { udid ->
            try {
                InputValidator.validateUDID(udid)
            } catch (_: Exception) {
                return@mapNotNull null
            }
            try {
                fetchDeviceInfo(udid, ideviceInfo)
            } catch (_: Exception) {
                null
            }
        }
    }

    /** `idevicepair validate -u <udid>` → maps to [TrustState]. Best-effort: swallows errors. */
    suspend fun validateTrust(udid: String): TrustState {
        try {
            InputValidator.validateUDID(udid)
        } catch (_: Exception) {
            return TrustState.NOT_TRUSTED
        }

        val idevicepair = paths.optional("idevicepair") ?: return TrustState.NOT_TRUSTED

        val result = try {
            runner.run(
                executablePath = idevicepair,
                arguments = listOf("validate", "-u", udid),
                timeoutSeconds = 5.0
            )
        } catch (_: Exception) {
            return TrustState.NOT_TRUSTED
        }

        val output = (result.stdout.decodeToString() + result.stderr.decodeToString()).lowercase()
        return when {
            result.exitCode == 0 ||
                output.contains("success") ||
                output.contains("validated") -> TrustState.TRUSTED

            output.contains("dialog_response_pending") ||
                output.contains("pairing_dialog") -> TrustState.DIALOG_SHOWN

            else -> TrustState.NOT_TRUSTED
        }
    }

    /** `ideviceinstaller -u <udid> list --xml` → parsed plist → [AppInfo] list. */
    suspend fun listApps(udid: String): List<AppInfo> {
        InputValidator.validateUDID(udid)
        val ideviceinstaller = paths.require("ideviceinstaller")

        val result = runner.run(
            executablePath = ideviceinstaller,
            arguments = listOf("-u", udid, "list", "--xml"),
            timeoutSeconds = 30.0
        )

        if (result.exitCode != 0) {
            val stderr = result.stderr.decodeToString().trim()
            throw SpacieError.ProcessExitedWithError("ideviceinstaller", result.exitCode, stderr)
        }

        return parseAppList(result.stdout)
    }

    /** `ideviceinstaller -u <udid> install <ipa>` with progress parsing. */
    suspend fun installIPA(udid: String, ipaPath: String, onProgress: (Double) -> Unit) {
        InputValidator.validateUDID(udid)
        if (!pathExists(ipaPath)) throw SpacieError.IpaFileNotFound(ipaPath)

        val ideviceinstaller = paths.require("ideviceinstaller")

        val result = runner.runWithLineOutput(
            executablePath = ideviceinstaller,
            arguments = listOf("-u", udid, "install", ipaPath),
            timeoutSeconds = 120.0,
            onLine = { line ->
                DeviceServiceHelpers.parseProgressLine(line)?.let { onProgress(it) }
            }
        )

        if (result.exitCode != 0) {
            val stderr = result.stderr.decodeToString().trim()
            val bundleID = ipaPath.substringAfterLast("/").removeSuffix(".ipa")
            throw SpacieError.InstallFailed(bundleID, stderr)
        }
    }

    // -- Private --

    private suspend fun fetchDeviceInfo(udid: String, ideviceInfoPath: String): DeviceInfo {
        val result = runner.run(
            executablePath = ideviceInfoPath,
            arguments = listOf("-u", udid),
            timeoutSeconds = 5.0
        )

        val dict = DeviceServiceHelpers.parseKeyValueOutput(result.stdout.decodeToString())

        return DeviceInfo(
            udid = udid,
            deviceName = InputValidator.sanitizeDisplayName(dict["DeviceName"] ?: udid, 100),
            productType = dict["ProductType"] ?: "Unknown",
            productVersion = dict["ProductVersion"] ?: "Unknown",
            buildVersion = dict["BuildVersion"] ?: "Unknown"
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseAppList(data: ByteArray): List<AppInfo> {
        if (data.isEmpty()) return emptyList()

        val nsData: NSData = data.usePinned { pin ->
            NSData.dataWithBytes(pin.addressOf(0), length = data.size.toULong()) ?: NSData()
        }

        val plist: Any? = memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            NSPropertyListSerialization.propertyListWithData(
                data = nsData,
                options = NSPropertyListMutableContainersAndLeaves,
                format = null,
                error = errorPtr.ptr
            )
        }

        val array = plist as? List<Any?> ?: return emptyList()

        return array.mapNotNull { item ->
            val dict = item as? Map<Any?, Any?> ?: return@mapNotNull null
            val bundleID = dict["CFBundleIdentifier"] as? String ?: return@mapNotNull null

            try {
                InputValidator.validateBundleID(bundleID)
            } catch (_: Exception) {
                return@mapNotNull null
            }

            val displayName = (dict["CFBundleDisplayName"] as? String)
                ?: (dict["CFBundleName"] as? String)
                ?: bundleID
            val version = (dict["CFBundleVersion"] as? String) ?: "0"
            val shortVersion = (dict["CFBundleShortVersionString"] as? String) ?: version
            val ipaSize = when (val raw = dict["StaticDiskUsage"]) {
                is NSNumber -> raw.longLongValue
                else -> null
            }

            AppInfo(
                bundleID = bundleID,
                displayName = InputValidator.sanitizeDisplayName(displayName, 100),
                version = version,
                shortVersion = shortVersion,
                ipaSize = ipaSize,
                iconData = null
            )
        }
    }
}
