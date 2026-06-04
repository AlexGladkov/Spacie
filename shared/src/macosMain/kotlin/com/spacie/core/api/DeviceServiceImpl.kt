package com.spacie.core.api

import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.flow.CommonFlow
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceEvent
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TransferProgress
import com.spacie.core.model.TrustState
import com.spacie.core.platform.HomebrewResolver
import com.spacie.core.platform.ProcessRunner
import com.spacie.core.platform.ProcessRunnerApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * macOS implementation of [DeviceServiceApi] backed by Homebrew-installed
 * iMobileDevice + ipatool CLIs.
 *
 * Façade composing four single-responsibility collaborators (Sprint 4.5):
 *  - [DependencyManagerMac] — checkDependencies / installDependencies
 *  - [IpaToolClient]        — Apple ID auth + IPA download
 *  - [IDeviceClient]        — device enumeration + trust + listApps + installIPA
 *  - [TransferOrchestrator] — per-item transferApps loop + observeDevices polling
 *  - [IpaArchiveWriter]     — IPA archive copy + metadata.json
 *
 * Each collaborator is constructor-injected so the production wiring uses real
 * binaries while tests substitute a `FakeProcessRunner`-backed setup.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceImpl")
class DeviceServiceImpl internal constructor(
    private val dependencies: DependencyManagerMac,
    private val ipaTool: IpaToolClient,
    private val iDevice: IDeviceClient,
    private val orchestrator: TransferOrchestrator,
) : DeviceServiceApi {

    /**
     * Production constructor — wires the real Homebrew resolver + platform
     * [ProcessRunner].
     */
    constructor(
        runner: ProcessRunnerApi = ProcessRunner(),
        resolver: HomebrewResolver = HomebrewResolver(),
        archiveWriter: IpaArchiveWriter = IpaArchiveWriter(),
    ) : this(
        dependencies = DependencyManagerMac(runner, resolver),
        ipaTool = IpaToolClient(runner, ToolPaths(resolver)),
        iDevice = IDeviceClient(runner, ToolPaths(resolver)),
        orchestrator = TransferOrchestrator(
            ipaTool = IpaToolClient(runner, ToolPaths(resolver)),
            iDevice = IDeviceClient(runner, ToolPaths(resolver)),
            archiveWriter = archiveWriter,
        ),
    )

    /**
     * Bound to in-flight observation / transfer coroutines (see [cancel]).
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // -- DependencyManagerApi (delegated to [dependencies]) --

    override suspend fun checkDependencies(): DependencyStatus =
        dependencies.checkDependencies()

    override suspend fun installDependencies(onLine: (String) -> Unit) =
        dependencies.installDependencies(onLine)

    // -- DeviceDiscoveryApi (delegated to [iDevice] / [orchestrator]) --

    override suspend fun listDevices(): List<DeviceInfo> = iDevice.listDevices()

    override suspend fun validateTrust(udid: String): TrustState =
        iDevice.validateTrust(udid)

    override fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent> =
        orchestrator.observeDevices(pollingIntervalSeconds)

    // -- AppleIDAuthApi (delegated to [ipaTool]) --

    override suspend fun checkAppleIDAuth(): Boolean = ipaTool.checkAppleIDAuth()

    override suspend fun loginAppleID(email: String, password: String, authCode: String?) =
        ipaTool.loginAppleID(email, password, authCode)

    // -- AppTransferApi (delegated to clients + orchestrator) --

    override suspend fun listApps(udid: String): List<AppInfo> = iDevice.listApps(udid)

    override suspend fun extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String = ipaTool.downloadIPA(bundleID, destinationDir, onProgress)

    override suspend fun installIPA(udid: String, ipaPath: String, onProgress: (Double) -> Unit) =
        iDevice.installIPA(udid, ipaPath, onProgress)

    override fun transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: List<AppInfo>,
        archiveDir: String?,
        shouldInstall: Boolean
    ): CommonFlow<TransferProgress> = orchestrator.transferApps(
        sourceUDID = sourceUDID,
        destinationUDID = destinationUDID,
        apps = apps,
        archiveDir = archiveDir,
        shouldInstall = shouldInstall
    )

    /**
     * Cancels the service-owned scope. The cold `flow {}` blocks returned by
     * [observeDevices] / [transferApps] honour their **collector's**
     * cancellation, not this scope — cancelling the coroutine that collects
     * the flow is the primary stop mechanism.
     */
    override fun cancel() {
        scope.cancel()
    }
}
