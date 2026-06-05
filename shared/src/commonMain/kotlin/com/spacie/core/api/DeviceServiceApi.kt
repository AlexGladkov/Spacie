package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.flow.CommonFlow
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceEvent
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TransferProgress
import com.spacie.core.model.TrustState
import kotlin.coroutines.cancellation.CancellationException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDependencyStatus")
sealed class DependencyStatus {
    @ObjCName("SpaDependencyStatusReady")
    data class Ready(val toolPaths: Map<String, String>) : DependencyStatus()

    @ObjCName("SpaDependencyStatusMissing")
    data class Missing(val tools: List<String>) : DependencyStatus()

    @ObjCName("SpaDependencyStatusPackageManagerMissing")
    data class PackageManagerMissing(
        val managerName: String,
        val installUrl: String
    ) : DependencyStatus()
}

// ----------------------------------------------------------------------------
// Sub-interfaces (ISP — Interface Segregation Principle)
//
// Splitting the original monolithic DeviceServiceApi into four narrow
// interfaces means consumers can depend only on what they actually use.
// A pure listDevices() caller no longer has to know about transferApps,
// installDependencies, or loginAppleID.
//
// DeviceServiceApi remains as a composite for backwards compatibility with
// the Swift adapter, Compose VM, and DeviceServiceFactory call sites.
// ----------------------------------------------------------------------------

/** Dependency discovery + install lifecycle. */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDependencyManagerApi")
interface DependencyManagerApi {
    suspend fun checkDependencies(): DependencyStatus

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun installDependencies(onLine: (String) -> Unit)
}

/** Connected-device discovery + trust state. */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceDiscoveryApi")
interface DeviceDiscoveryApi {
    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listDevices(): List<DeviceInfo>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun validateTrust(udid: String): TrustState

    fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent>
}

/** Apple ID session management for ipatool. */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaAppleIDAuthApi")
interface AppleIDAuthApi {
    suspend fun checkAppleIDAuth(): Boolean

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun loginAppleID(email: String, password: String, authCode: String?)
}

/** App listing + IPA extraction/installation/transfer. */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaAppTransferApi")
interface AppTransferApi {
    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listApps(udid: String): List<AppInfo>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun installIPA(
        udid: String,
        ipaPath: String,
        onProgress: (Double) -> Unit
    )

    fun transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: List<AppInfo>,
        archiveDir: String?,
        shouldInstall: Boolean
    ): CommonFlow<TransferProgress>
}

/**
 * Composite façade combining all device-side capabilities.
 *
 * Existing call sites (Swift KMP adapter, Compose VM, KMP factories) keep
 * depending on this single type. New code may pick the narrower sub-interface
 * it actually needs (ISP).
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceApi")
interface DeviceServiceApi :
    DependencyManagerApi,
    DeviceDiscoveryApi,
    AppleIDAuthApi,
    AppTransferApi {

    /** Cancel any service-owned background work. */
    fun cancel()
}
