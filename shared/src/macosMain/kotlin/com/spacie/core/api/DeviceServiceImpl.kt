@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.flow.CommonFlow
import com.spacie.core.flow.asCommonFlow
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceEvent
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TransferItem
import com.spacie.core.model.TransferPhase
import com.spacie.core.model.TransferProgress
import com.spacie.core.model.TrustState
import com.spacie.core.platform.HomebrewResolver
import com.spacie.core.platform.ProcessRunner
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
import kotlinx.cinterop.value
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import platform.Foundation.NSData
import platform.Foundation.NSDate
import platform.Foundation.NSError
import platform.Foundation.timeIntervalSince1970
import platform.Foundation.NSFileManager
import platform.Foundation.NSFilePosixPermissions
import platform.Foundation.NSFileSize
import platform.Foundation.NSNumber
import platform.Foundation.NSPropertyListMutableContainersAndLeaves
import platform.Foundation.NSPropertyListSerialization
import platform.Foundation.NSTemporaryDirectory
import platform.Foundation.NSUUID
import platform.Foundation.create
import platform.Foundation.dataWithBytes
import platform.Foundation.writeToFile
import kotlin.coroutines.cancellation.CancellationException as KotlinCancellationException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * macOS implementation of [DeviceServiceApi] backed by iMobileDevice CLI tools.
 *
 * Uses [HomebrewResolver] to locate tool binaries and [ProcessRunner] to execute them.
 * Plist output from `ideviceinstaller --xml` is parsed via [NSPropertyListSerialization].
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceImpl")
class DeviceServiceImpl : DeviceServiceApi {

    private val runner = ProcessRunner()
    private val resolver = HomebrewResolver()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // -- Dependencies --

    override suspend fun checkDependencies(): DependencyStatus = resolver.resolveAll()

    override suspend fun installDependencies(onLine: (String) -> Unit) {
        val brewPath = resolver.resolve("brew")
            ?: throw SpacieError.HomebrewNotInstalled

        val result = runner.runWithLineOutput(
            executablePath = brewPath,
            arguments = listOf("install", "libimobiledevice", "ideviceinstaller", "ipatool"),
            timeoutSeconds = 300.0,
            onLine = onLine
        )

        if (result.exitCode != 0) {
            val stderr = result.stderr.decodeToString().trim()
            throw SpacieError.DependencyInstallFailed(
                if (stderr.isEmpty()) "Exit code ${result.exitCode}" else stderr
            )
        }

        resolver.invalidateCache()
    }

    // -- Device Listing --

    override suspend fun listDevices(): List<DeviceInfo> {
        val paths = requireToolPaths()
        val ideviceId = paths["idevice_id"]
            ?: throw SpacieError.DependencyMissing(listOf("idevice_id"))
        val ideviceInfo = paths["ideviceinfo"]
            ?: throw SpacieError.DependencyMissing(listOf("ideviceinfo"))

        val result = runner.run(
            executablePath = ideviceId,
            arguments = listOf("-l"),
            timeoutSeconds = 10.0
        )

        val output = result.stdout.decodeToString()
        val udids = output.split("\n")
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

    // -- Trust Validation --

    override suspend fun validateTrust(udid: String): TrustState {
        try {
            InputValidator.validateUDID(udid)
        } catch (_: Exception) {
            return TrustState.NOT_TRUSTED
        }

        val paths = try {
            requireToolPaths()
        } catch (_: Exception) {
            return TrustState.NOT_TRUSTED
        }

        val idevicepair = paths["idevicepair"] ?: return TrustState.NOT_TRUSTED

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

    // -- App Listing --

    override suspend fun listApps(udid: String): List<AppInfo> {
        InputValidator.validateUDID(udid)
        val paths = requireToolPaths()
        val ideviceinstaller = paths["ideviceinstaller"]
            ?: throw SpacieError.DependencyMissing(listOf("ideviceinstaller"))

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

    // -- Apple ID Authentication --

    override suspend fun checkAppleIDAuth(): Boolean {
        val paths = try {
            requireToolPaths()
        } catch (_: Exception) {
            return false
        }

        val ipatool = paths["ipatool"] ?: return false

        val result = try {
            runner.run(
                executablePath = ipatool,
                arguments = listOf("auth", "info"),
                timeoutSeconds = 10.0
            )
        } catch (_: Exception) {
            return false
        }

        return result.exitCode == 0
    }

    override suspend fun loginAppleID(email: String, password: String, authCode: String?) {
        val paths = requireToolPaths()
        val ipatool = paths["ipatool"]
            ?: throw SpacieError.DependencyMissing(listOf("ipatool"))

        val args = mutableListOf("auth", "login", "--email", email, "--password", password)
        if (!authCode.isNullOrEmpty()) {
            args += listOf("--auth-code", authCode)
        }

        val result = runner.run(
            executablePath = ipatool,
            arguments = args,
            timeoutSeconds = 30.0
        )

        if (result.exitCode != 0) {
            val raw = (result.stdout.decodeToString() + "\n" + result.stderr.decodeToString()).trim()
            val cleaned = stripANSI(raw).trim()
            val lowered = cleaned.lowercase()

            val twoFAKeywords = listOf(
                "two-factor", "2fa", "auth-code", "authentication code",
                "verification code", "two factor", "mfa"
            )

            if (authCode == null && twoFAKeywords.any { lowered.contains(it) }) {
                throw SpacieError.TwoFactorRequired
            }

            throw SpacieError.AuthFailed(
                if (cleaned.isEmpty()) "Authentication failed" else cleaned
            )
        }
    }

    // -- IPA Extraction --

    override suspend fun extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String {
        InputValidator.validateUDID(udid)
        InputValidator.validateBundleID(bundleID)
        val paths = requireToolPaths()
        val ipatool = paths["ipatool"]
            ?: throw SpacieError.DependencyMissing(listOf("ipatool"))

        if (!checkAppleIDAuth()) {
            throw SpacieError.ExtractionFailed(
                bundleID,
                "Not signed in with Apple ID. Please sign in first."
            )
        }

        val ipaPath = "$destinationDir/$bundleID.ipa"
        onProgress(0.1)

        val result = runner.runWithLineOutput(
            executablePath = ipatool,
            arguments = listOf("download", "-b", bundleID, "-o", ipaPath, "--purchase"),
            timeoutSeconds = 300.0,
            onLine = { onProgress(0.5) }
        )

        if (result.exitCode != 0) {
            val raw = (result.stdout.decodeToString() + "\n" + result.stderr.decodeToString()).trim()
            val out = stripANSI(raw).trim()
            throw SpacieError.ExtractionFailed(
                bundleID,
                if (out.isEmpty()) "ipatool exited with code ${result.exitCode}" else out
            )
        }

        if (!pathExists(ipaPath)) {
            throw SpacieError.ExtractionFailed(bundleID, "IPA was not downloaded to expected path")
        }

        onProgress(1.0)
        return ipaPath
    }

    // -- IPA Installation --

    override suspend fun installIPA(
        udid: String,
        ipaPath: String,
        onProgress: (Double) -> Unit
    ) {
        InputValidator.validateUDID(udid)
        if (!pathExists(ipaPath)) throw SpacieError.IpaFileNotFound(ipaPath)

        val paths = requireToolPaths()
        val ideviceinstaller = paths["ideviceinstaller"]
            ?: throw SpacieError.DependencyMissing(listOf("ideviceinstaller"))

        val result = runner.runWithLineOutput(
            executablePath = ideviceinstaller,
            arguments = listOf("-u", udid, "install", ipaPath),
            timeoutSeconds = 120.0,
            onLine = { line ->
                parseProgressLine(line)?.let { onProgress(it) }
            }
        )

        if (result.exitCode != 0) {
            val stderr = result.stderr.decodeToString().trim()
            val bundleID = ipaPath.substringAfterLast("/").removeSuffix(".ipa")
            throw SpacieError.InstallFailed(bundleID, stderr)
        }
    }

    // -- Transfer --

    override fun transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: List<AppInfo>,
        archiveDir: String?,
        shouldInstall: Boolean
    ): CommonFlow<TransferProgress> {
        return flow {
            var items = apps.map {
                TransferItem(
                    id = it.bundleID,
                    app = it,
                    phase = TransferPhase.PENDING,
                    progress = 0.0,
                    errorMessage = null
                )
            }

            val fm = NSFileManager.defaultManager

            for (i in items.indices) {
                if (!currentCoroutineContext().isActive) break
                val app = items[i].app

                // Create temporary working directory
                val tempDir = NSTemporaryDirectory() + NSUUID().UUIDString
                val dirCreated = memScoped {
                    val errorPtr = alloc<ObjCObjectVar<NSError?>>()
                    fm.createDirectoryAtPath(
                        tempDir,
                        withIntermediateDirectories = true,
                        attributes = null,
                        error = errorPtr.ptr
                    )
                }

                if (!dirCreated) {
                    items = items.toMutableList().also { list ->
                        list[i] = list[i].copy(
                            phase = TransferPhase.FAILED,
                            errorMessage = "Failed to create temp dir"
                        )
                    }
                    emit(TransferProgress(items, i))
                    continue
                }

                try {
                    // Phase 1: Extract IPA
                    items = items.toMutableList().also {
                        it[i] = it[i].copy(phase = TransferPhase.EXTRACTING)
                    }
                    emit(TransferProgress(items, i))

                    val ipaPath = extractIPA(
                        udid = sourceUDID,
                        bundleID = app.bundleID,
                        destinationDir = tempDir,
                        onProgress = {}
                    )

                    // Phase 2: Archive (optional)
                    if (archiveDir != null) {
                        items = items.toMutableList().also {
                            it[i] = it[i].copy(phase = TransferPhase.ARCHIVING)
                        }
                        emit(TransferProgress(items, i))
                        writeToArchive(
                            ipaPath = ipaPath,
                            app = app,
                            archiveDir = archiveDir,
                            fm = fm
                        )
                    }

                    // Phase 3: Install on destination device (optional)
                    if (shouldInstall && destinationUDID != null) {
                        items = items.toMutableList().also {
                            it[i] = it[i].copy(phase = TransferPhase.INSTALLING)
                        }
                        emit(TransferProgress(items, i))
                        installIPA(
                            udid = destinationUDID,
                            ipaPath = ipaPath,
                            onProgress = {}
                        )
                    }

                    items = items.toMutableList().also {
                        it[i] = it[i].copy(phase = TransferPhase.COMPLETED, progress = 1.0)
                    }
                    emit(TransferProgress(items, i))

                } catch (e: CancellationException) {
                    throw e
                } catch (e: KotlinCancellationException) {
                    throw e
                } catch (e: Exception) {
                    items = items.toMutableList().also {
                        it[i] = it[i].copy(
                            phase = TransferPhase.FAILED,
                            errorMessage = e.message
                        )
                    }
                    emit(TransferProgress(items, i))
                } finally {
                    // Cleanup temp directory
                    fm.removeItemAtPath(tempDir, error = null)
                }
            }
        }.asCommonFlow()
    }

    // -- Device Observation --

    override fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent> {
        val interval = maxOf(1.0, pollingIntervalSeconds)

        return flow {
            var knownUDIDs = emptySet<String>()
            val knownTrustStates = mutableMapOf<String, TrustState>()

            while (true) {
                try {
                    val devices = listDevices()
                    val currentUDIDs = devices.map { it.udid }.toSet()

                    // Emit Connected events for newly discovered devices
                    for (device in devices) {
                        if (device.udid !in knownUDIDs) {
                            emit(DeviceEvent.Connected(device))
                        }
                    }

                    // Emit Disconnected events for removed devices
                    for (udid in knownUDIDs) {
                        if (udid !in currentUDIDs) {
                            emit(DeviceEvent.Disconnected(udid))
                            knownTrustStates.remove(udid)
                        }
                    }

                    knownUDIDs = currentUDIDs

                    // Check trust state changes for all connected devices
                    for (device in devices) {
                        val newState = validateTrust(device.udid)
                        if (knownTrustStates[device.udid] != newState) {
                            knownTrustStates[device.udid] = newState
                            emit(DeviceEvent.TrustStateChanged(device.udid, newState))
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: KotlinCancellationException) {
                    throw e
                } catch (e: Exception) {
                    emit(DeviceEvent.Error(e.message ?: "Unknown error"))
                }

                delay((interval * 1000).toLong())
            }
        }.asCommonFlow()
    }

    // -- Cancellation --

    override fun cancel() {
        scope.cancel()
    }

    // -- Private Helpers --

    private fun requireToolPaths(): Map<String, String> {
        return when (val status = resolver.resolveAll()) {
            is DependencyStatus.Ready -> status.toolPaths
            is DependencyStatus.Missing -> throw SpacieError.DependencyMissing(status.tools)
            is DependencyStatus.HomebrewMissing -> throw SpacieError.HomebrewNotInstalled
        }
    }

    private suspend fun fetchDeviceInfo(udid: String, ideviceInfoPath: String): DeviceInfo {
        val result = runner.run(
            executablePath = ideviceInfoPath,
            arguments = listOf("-u", udid),
            timeoutSeconds = 5.0
        )

        val dict = parseKeyValueOutput(result.stdout.decodeToString())

        return DeviceInfo(
            udid = udid,
            deviceName = InputValidator.sanitizeDisplayName(dict["DeviceName"] ?: udid, 100),
            productType = dict["ProductType"] ?: "Unknown",
            productVersion = dict["ProductVersion"] ?: "Unknown",
            buildVersion = dict["BuildVersion"] ?: "Unknown"
        )
    }

    private fun parseKeyValueOutput(output: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        for (line in output.split("\n")) {
            val idx = line.indexOf(':')
            if (idx <= 0) continue
            val key = line.substring(0, idx).trim()
            val value = line.substring(idx + 1).trim()
            if (key.isNotEmpty()) result[key] = value
        }
        return result
    }

    @Suppress("UNCHECKED_CAST")
    private fun parseAppList(data: ByteArray): List<AppInfo> {
        if (data.isEmpty()) return emptyList()

        val nsData: NSData = data.toNSData()

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

    private fun parseProgressLine(line: String): Double? {
        val regex = Regex("""(\d+(?:\.\d+)?)\s*%""")
        val match = regex.find(line) ?: return null
        val value = match.groupValues[1].toDoubleOrNull() ?: return null
        return minOf(1.0, value / 100.0)
    }

    private fun stripANSI(s: String): String =
        s.replace(Regex("\u001B\\[[0-9;]*[mGKHFJA-Z]"), "")

    private fun writeToArchive(
        ipaPath: String,
        app: AppInfo,
        archiveDir: String,
        fm: NSFileManager
    ) {
        // Create archive directory if needed
        fm.createDirectoryAtPath(
            archiveDir,
            withIntermediateDirectories = true,
            attributes = null,
            error = null
        )

        // Create unique subdirectory for this archive entry
        val archiveSubDir = "$archiveDir/${NSUUID().UUIDString}"
        fm.createDirectoryAtPath(
            archiveSubDir,
            withIntermediateDirectories = true,
            attributes = null,
            error = null
        )

        val ipaFilename = ipaPath.substringAfterLast("/")
        val destIpaPath = "$archiveSubDir/$ipaFilename"

        // Copy IPA to archive
        memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            val copied = fm.copyItemAtPath(ipaPath, toPath = destIpaPath, error = errorPtr.ptr)
            if (!copied) {
                val errMsg = errorPtr.value?.localizedDescription ?: "Unknown error"
                throw SpacieError.ArchiveWriteFailed(destIpaPath, errMsg)
            }
        }

        // Set restrictive permissions (owner read+write only = 0600)
        fm.setAttributes(
            mapOf<Any?, Any?>(NSFilePosixPermissions to NSNumber(int = 0b110000000)),
            ofItemAtPath = destIpaPath,
            error = null
        )

        // Get file size for metadata
        val ipaSize: Long = memScoped {
            val errorPtr = alloc<ObjCObjectVar<NSError?>>()
            val attrs = fm.attributesOfItemAtPath(destIpaPath, error = errorPtr.ptr)
            (attrs?.get(NSFileSize) as? NSNumber)?.longLongValue ?: 0L
        }

        // Write metadata.json (manual serialization -- no kotlinx-serialization dependency)
        val now = NSDate().timeIntervalSince1970.toLong()
        val metaJson = buildMetadataJson(app, ipaSize, now)
        val metaPath = "$archiveSubDir/metadata.json"
        metaJson.encodeToByteArray().toNSData().writeToFile(metaPath, atomically = true)

        // Write icon if available
        app.iconData?.let { iconBytes ->
            val iconPath = "$archiveSubDir/icon.png"
            iconBytes.toNSData().writeToFile(iconPath, atomically = true)
        }
    }

    private fun buildMetadataJson(app: AppInfo, ipaSize: Long, archivedAt: Long): String {
        val sb = StringBuilder()
        sb.append("{")
        sb.append(""""bundleID":${jsonString(app.bundleID)},""")
        sb.append(""""displayName":${jsonString(app.displayName)},""")
        sb.append(""""version":${jsonString(app.version)},""")
        sb.append(""""shortVersion":${jsonString(app.shortVersion)},""")
        sb.append(""""ipaSize":$ipaSize,""")
        sb.append(""""archivedAt":$archivedAt""")
        sb.append("}")
        return sb.toString()
    }

    private fun jsonString(s: String): String {
        val escaped = s
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        return "\"$escaped\""
    }

    private fun ByteArray.toNSData(): NSData {
        if (isEmpty()) return NSData()
        return usePinned { pin ->
            NSData.dataWithBytes(pin.addressOf(0), length = size.toULong())
                ?: NSData()
        }
    }
}
