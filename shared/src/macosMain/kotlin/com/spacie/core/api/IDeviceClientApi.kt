package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TrustState
import kotlin.coroutines.cancellation.CancellationException

/**
 * Boundary for the libimobiledevice CLI client (idevice_id, ideviceinfo,
 * idevicepair, ideviceinstaller). Extracted so [TransferOrchestrator] can be
 * unit-tested with a fake that records calls and emits scripted device lists,
 * trust states, and install outcomes without spawning real binaries.
 */
internal interface IDeviceClientApi {

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listDevices(): List<DeviceInfo>

    /** Best-effort: returns [TrustState.NOT_TRUSTED] on any failure. */
    suspend fun validateTrust(udid: String): TrustState

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun listApps(udid: String): List<AppInfo>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun installIPA(udid: String, ipaPath: String, onProgress: (Double) -> Unit)
}
