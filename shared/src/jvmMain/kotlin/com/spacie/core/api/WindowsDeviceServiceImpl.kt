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
import com.spacie.core.platform.ChocolateyResolver
import com.spacie.core.platform.ProcessRunner
import com.spacie.core.platform.pathExists
import com.spacie.core.validation.InputValidator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import org.w3c.dom.Element
import java.io.File
import java.util.UUID
import javax.xml.parsers.DocumentBuilderFactory

/**
 * JVM (Windows-primary) implementation of [DeviceServiceApi].
 *
 * Uses [ChocolateyResolver] for tool discovery and [ProcessRunner] for
 * invoking libimobiledevice / ipatool CLI tools.
 */
class WindowsDeviceServiceImpl : DeviceServiceApi {

    private val runner = ProcessRunner()
    private val resolver = ChocolateyResolver()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // -- Dependencies --

    override suspend fun checkDependencies(): DependencyStatus = resolver.resolveAll()

    override suspend fun installDependencies(onLine: (String) -> Unit) {
        val chocoPath = resolver.resolve("choco")
            ?: throw SpacieError.HomebrewNotInstalled

        val result = runner.runWithLineOutput(
            executablePath = chocoPath,
            arguments = listOf("install", "libimobiledevice", "ipatool", "-y", "--no-progress"),
            timeoutSeconds = 300.0,
            onLine = onLine
        )

        if (result.exitCode != 0) {
            val stderr = String(result.stderr, Charsets.UTF_8).trim()
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

        val result = runner.run(ideviceId, listOf("-l"), timeoutSeconds = 10.0)
        val udids = String(result.stdout, Charsets.UTF_8)
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

    // -- Trust --

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
            runner.run(idevicepair, listOf("validate", "-u", udid), timeoutSeconds = 5.0)
        } catch (_: Exception) {
            return TrustState.NOT_TRUSTED
        }

        val output = (String(result.stdout, Charsets.UTF_8) +
                String(result.stderr, Charsets.UTF_8)).lowercase()

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
            ideviceinstaller,
            listOf("-u", udid, "list", "--xml"),
            timeoutSeconds = 30.0
        )

        if (result.exitCode != 0) {
            throw SpacieError.ProcessExitedWithError(
                "ideviceinstaller",
                result.exitCode,
                String(result.stderr, Charsets.UTF_8)
            )
        }
        return parseAppListXml(result.stdout)
    }

    // -- Apple ID --

    override suspend fun checkAppleIDAuth(): Boolean {
        val paths = try {
            requireToolPaths()
        } catch (_: Exception) {
            return false
        }
        val ipatool = paths["ipatool"] ?: return false
        return try {
            runner.run(ipatool, listOf("auth", "info"), timeoutSeconds = 10.0).exitCode == 0
        } catch (_: Exception) {
            false
        }
    }

    override suspend fun loginAppleID(email: String, password: String, authCode: String?) {
        val paths = requireToolPaths()
        val ipatool = paths["ipatool"]
            ?: throw SpacieError.DependencyMissing(listOf("ipatool"))

        val args = mutableListOf("auth", "login", "--email", email, "--password", password)
        if (!authCode.isNullOrEmpty()) {
            args += listOf("--auth-code", authCode)
        }

        val result = runner.run(ipatool, args, timeoutSeconds = 30.0)
        if (result.exitCode != 0) {
            val raw = (String(result.stdout, Charsets.UTF_8) + "\n" +
                    String(result.stderr, Charsets.UTF_8)).trim()
            val twoFaKeywords = listOf(
                "two-factor", "2fa", "auth-code",
                "authentication code", "verification code"
            )
            if (authCode == null && twoFaKeywords.any { raw.lowercase().contains(it) }) {
                throw SpacieError.TwoFactorRequired
            }
            throw SpacieError.AuthFailed(raw.ifEmpty { "Authentication failed" })
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
            throw SpacieError.ExtractionFailed(bundleID, "Not signed in with Apple ID")
        }

        val ipaPath = "$destinationDir${File.separator}$bundleID.ipa"
        onProgress(0.1)

        val result = runner.runWithLineOutput(
            executablePath = ipatool,
            arguments = listOf("download", "-b", bundleID, "-o", ipaPath, "--purchase"),
            timeoutSeconds = 300.0,
            onLine = { onProgress(0.5) }
        )

        if (result.exitCode != 0) {
            val out = (String(result.stdout, Charsets.UTF_8) + "\n" +
                    String(result.stderr, Charsets.UTF_8)).trim()
            throw SpacieError.ExtractionFailed(
                bundleID,
                out.ifEmpty { "Exit ${result.exitCode}" }
            )
        }

        if (!pathExists(ipaPath)) {
            throw SpacieError.ExtractionFailed(bundleID, "IPA not found at expected path")
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
            onLine = { line -> parseProgressLine(line)?.let { onProgress(it) } }
        )

        if (result.exitCode != 0) {
            val bundleID = File(ipaPath).nameWithoutExtension
            throw SpacieError.InstallFailed(
                bundleID,
                String(result.stderr, Charsets.UTF_8)
            )
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
            val tmpBase = System.getProperty("java.io.tmpdir")

            for (i in items.indices) {
                if (!currentCoroutineContext().isActive) break
                val app = items[i].app
                val tempDir = File(tmpBase, UUID.randomUUID().toString())
                tempDir.mkdirs()

                try {
                    items = items.toMutableList().also {
                        it[i] = it[i].copy(phase = TransferPhase.EXTRACTING)
                    }
                    emit(TransferProgress(items, i))

                    val ipaPath = extractIPA(sourceUDID, app.bundleID, tempDir.absolutePath) {}

                    if (archiveDir != null) {
                        items = items.toMutableList().also {
                            it[i] = it[i].copy(phase = TransferPhase.ARCHIVING)
                        }
                        emit(TransferProgress(items, i))

                        val archiveSubDir = File(archiveDir, UUID.randomUUID().toString())
                        archiveSubDir.mkdirs()
                        File(ipaPath).copyTo(
                            File(archiveSubDir, File(ipaPath).name),
                            overwrite = true
                        )
                    }

                    if (shouldInstall && destinationUDID != null) {
                        items = items.toMutableList().also {
                            it[i] = it[i].copy(phase = TransferPhase.INSTALLING)
                        }
                        emit(TransferProgress(items, i))
                        installIPA(destinationUDID, ipaPath) {}
                    }

                    items = items.toMutableList().also {
                        it[i] = it[i].copy(phase = TransferPhase.COMPLETED, progress = 1.0)
                    }
                    emit(TransferProgress(items, i))

                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    items = items.toMutableList().also {
                        it[i] = it[i].copy(phase = TransferPhase.FAILED, errorMessage = e.message)
                    }
                    emit(TransferProgress(items, i))
                } finally {
                    tempDir.deleteRecursively()
                }
            }
        }.asCommonFlow()
    }

    // -- Device Observation --

    override fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent> {
        val intervalMs = (maxOf(1.0, pollingIntervalSeconds) * 1000).toLong()
        return flow {
            var knownUDIDs = emptySet<String>()
            val knownTrustStates = mutableMapOf<String, TrustState>()

            while (true) {
                try {
                    val devices = listDevices()
                    val currentUDIDs = devices.map { it.udid }.toSet()

                    for (device in devices) {
                        if (device.udid !in knownUDIDs) {
                            emit(DeviceEvent.Connected(device))
                        }
                    }
                    for (udid in knownUDIDs) {
                        if (udid !in currentUDIDs) {
                            emit(DeviceEvent.Disconnected(udid))
                            knownTrustStates.remove(udid)
                        }
                    }
                    knownUDIDs = currentUDIDs

                    for (device in devices) {
                        val newState = validateTrust(device.udid)
                        if (knownTrustStates[device.udid] != newState) {
                            knownTrustStates[device.udid] = newState
                            emit(DeviceEvent.TrustStateChanged(device.udid, newState))
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    // Swallow transient errors; will retry on next poll
                }

                delay(intervalMs)
            }
        }.asCommonFlow()
    }

    override fun cancel() {
        scope.cancel()
    }

    // -- Private helpers --

    private fun requireToolPaths(): Map<String, String> {
        return when (val status = resolver.resolveAll()) {
            is DependencyStatus.Ready -> status.toolPaths
            is DependencyStatus.Missing -> throw SpacieError.DependencyMissing(status.tools)
            is DependencyStatus.HomebrewMissing -> throw SpacieError.HomebrewNotInstalled
        }
    }

    private suspend fun fetchDeviceInfo(udid: String, ideviceInfoPath: String): DeviceInfo {
        val result = runner.run(ideviceInfoPath, listOf("-u", udid), timeoutSeconds = 5.0)
        val dict = parseKeyValueOutput(String(result.stdout, Charsets.UTF_8))
        return DeviceInfo(
            udid = udid,
            deviceName = InputValidator.sanitizeDisplayName(
                dict["DeviceName"] ?: udid, 100
            ),
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
            result[line.substring(0, idx).trim()] = line.substring(idx + 1).trim()
        }
        return result
    }

    private fun parseAppListXml(data: ByteArray): List<AppInfo> {
        if (data.isEmpty()) return emptyList()
        return try {
            val doc = DocumentBuilderFactory.newInstance()
                .newDocumentBuilder()
                .parse(data.inputStream())
            val arrays = doc.getElementsByTagName("array")
            if (arrays.length == 0) return emptyList()

            val array = arrays.item(0)
            val apps = mutableListOf<AppInfo>()

            for (i in 0 until array.childNodes.length) {
                val dict = array.childNodes.item(i) as? Element ?: continue
                val map = mutableMapOf<String, String>()

                var j = 0
                while (j < dict.childNodes.length) {
                    val node = dict.childNodes.item(j)
                    if (node.nodeName == "key" && j + 1 < dict.childNodes.length) {
                        val valueNode = dict.childNodes.item(j + 1)
                        map[node.textContent] = valueNode.textContent
                        j += 2
                    } else {
                        j++
                    }
                }

                val bundleID = map["CFBundleIdentifier"] ?: continue
                try {
                    InputValidator.validateBundleID(bundleID)
                } catch (_: Exception) {
                    continue
                }

                apps.add(
                    AppInfo(
                        bundleID = bundleID,
                        displayName = InputValidator.sanitizeDisplayName(
                            map["CFBundleDisplayName"] ?: map["CFBundleName"] ?: bundleID,
                            100
                        ),
                        version = map["CFBundleVersion"] ?: "0",
                        shortVersion = map["CFBundleShortVersionString"]
                            ?: map["CFBundleVersion"] ?: "0",
                        ipaSize = map["StaticDiskUsage"]?.toLongOrNull(),
                        iconData = null
                    )
                )
            }
            apps
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun parseProgressLine(line: String): Double? {
        val match = Regex("""(\d+(?:\.\d+)?)\s*%""").find(line) ?: return null
        val percent = match.groupValues[1].toDoubleOrNull() ?: return null
        return minOf(1.0, percent / 100.0)
    }
}
