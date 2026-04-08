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

    @ObjCName("SpaDependencyStatusHomebrewMissing")
    data object HomebrewMissing : DependencyStatus()
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceApi")
interface DeviceServiceApi {

    suspend fun checkDependencies(): DependencyStatus

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun installDependencies(onLine: (String) -> Unit)

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listDevices(): List<DeviceInfo>

    fun observeDevices(pollingIntervalSeconds: Double): CommonFlow<DeviceEvent>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listApps(udid: String): List<AppInfo>

    fun cancel()

    // -- Trust & Authentication --

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun validateTrust(udid: String): TrustState

    suspend fun checkAppleIDAuth(): Boolean

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun loginAppleID(email: String, password: String, authCode: String?)

    // -- IPA Extraction & Installation --

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

    // -- Transfer --

    fun transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: List<AppInfo>,
        archiveDir: String?,
        shouldInstall: Boolean
    ): CommonFlow<TransferProgress>
}
