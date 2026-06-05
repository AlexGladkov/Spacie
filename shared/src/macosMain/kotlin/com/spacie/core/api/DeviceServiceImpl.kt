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
     * [ProcessRunner]. Shares a single [ToolPaths] instance and a single
     * [IpaToolClient]/[IDeviceClient] across the facade and orchestrator so
     * the object graph stays minimal and HomebrewResolver's cache is reused.
     */
    internal constructor(
        runner: ProcessRunnerApi = ProcessRunner(),
        resolver: HomebrewResolver = HomebrewResolver(),
        archiveWriter: IpaArchiveWriterApi = IpaArchiveWriter(),
    ) : this(
        runner = runner,
        toolPaths = ToolPaths(resolver),
        archiveWriter = archiveWriter,
        dependenciesFactory = { DependencyManagerMac(runner, resolver) },
    )

    /**
     * Helper constructor — shares a single [ToolPaths] (and therefore a single
     * pair of clients) across this facade and the orchestrator.
     */
    private constructor(
        runner: ProcessRunnerApi,
        toolPaths: ToolPaths,
        archiveWriter: IpaArchiveWriterApi,
        dependenciesFactory: () -> DependencyManagerMac,
    ) : this(
        ipaTool = IpaToolClient(runner, toolPaths),
        iDevice = IDeviceClient(runner, toolPaths),
        archiveWriter = archiveWriter,
        dependencies = dependenciesFactory(),
    )

    /**
     * Internal aggregating constructor — shares a single client pair between
     * facade and orchestrator, eliminating the previous 4× client duplication.
     */
    private constructor(
        ipaTool: IpaToolClient,
        iDevice: IDeviceClient,
        archiveWriter: IpaArchiveWriterApi,
        dependencies: DependencyManagerMac,
    ) : this(
        dependencies = dependencies,
        ipaTool = ipaTool,
        iDevice = iDevice,
        orchestrator = TransferOrchestrator(
            ipaTool = ipaTool,
            iDevice = iDevice,
            archiveWriter = archiveWriter,
        ),
    )

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

    /**
     * Extracts an IPA for [bundleID].
     *
     * `udid` is accepted at the API boundary for forward compatibility with
     * future device-bound extraction strategies (e.g. iTunes Backup parsing).
     * The current macOS implementation uses `ipatool`, which downloads from
     * the signed-in Apple ID account rather than directly from the device,
     * so `udid` is not forwarded to the binary.
     */
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
     * Documented no-op.
     *
     * The cold `flow {}` blocks returned by [observeDevices] / [transferApps]
     * honour the **collector's** cancellation, not any service-owned scope.
     * The previous implementation kept a `SupervisorJob` scope here that was
     * never used to `launch` anything — `cancel()` cancelled an empty scope
     * and gave callers the false impression that streams were being stopped.
     *
     * To stop a stream, cancel the coroutine that collects it (on Swift side:
     * cancel the `Task` consuming the `AsyncStream`).
     */
    override fun cancel() {
        // Intentionally empty. See KDoc.
    }
}
