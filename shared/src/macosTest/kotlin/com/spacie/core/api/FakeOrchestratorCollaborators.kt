package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.model.AppInfo
import com.spacie.core.model.DeviceInfo
import com.spacie.core.model.TrustState

/**
 * Fakes for [IpaToolClientApi], [IDeviceClientApi], [IpaArchiveWriterApi]
 * used by [TransferOrchestratorTest]. Records every call so tests can
 * assert per-app orchestration ordering and per-phase emission.
 */

internal class FakeIpaToolClient(
    var authResult: Boolean = true,
) : IpaToolClientApi {

    var downloadIPABehaviour: (suspend (String, String) -> String) = { bundleID, dest ->
        "$dest/$bundleID.ipa"
    }

    val downloadIPACalls = mutableListOf<String>()

    override suspend fun checkAppleIDAuth(): Boolean = authResult

    override suspend fun loginAppleID(email: String, password: String, authCode: String?) {
        // No-op for orchestrator tests.
    }

    override suspend fun downloadIPA(
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String {
        downloadIPACalls += bundleID
        onProgress(0.5)
        val path = downloadIPABehaviour(bundleID, destinationDir)
        onProgress(1.0)
        return path
    }
}

internal class FakeIDeviceClient(
    var devicesToReturn: List<DeviceInfo> = emptyList(),
    var trustStateToReturn: TrustState = TrustState.TRUSTED,
) : IDeviceClientApi {

    var installIPABehaviour: (suspend (String, String) -> Unit) = { _, _ -> }

    val installIPACalls = mutableListOf<Pair<String, String>>()
    val validateTrustCalls = mutableListOf<String>()
    val listDevicesCallCount get() = _listDevicesCallCount
    private var _listDevicesCallCount = 0

    override suspend fun listDevices(): List<DeviceInfo> {
        _listDevicesCallCount += 1
        return devicesToReturn
    }

    override suspend fun validateTrust(udid: String): TrustState {
        validateTrustCalls += udid
        return trustStateToReturn
    }

    override suspend fun listApps(udid: String): List<AppInfo> = emptyList()

    override suspend fun installIPA(
        udid: String,
        ipaPath: String,
        onProgress: (Double) -> Unit
    ) {
        installIPACalls += (udid to ipaPath)
        onProgress(0.5)
        installIPABehaviour(udid, ipaPath)
        onProgress(1.0)
    }
}

internal class FakeIpaArchiveWriter : IpaArchiveWriterApi {

    var writeBehaviour: (String, AppInfo, String) -> Unit = { _, _, _ -> }
    val writeCalls = mutableListOf<Triple<String, String, String>>() // (ipaPath, bundleID, archiveDir)

    override fun write(ipaPath: String, app: AppInfo, archiveDir: String) {
        writeCalls += Triple(ipaPath, app.bundleID, archiveDir)
        writeBehaviour(ipaPath, app, archiveDir)
    }
}

internal fun fakeApp(bundleID: String, name: String = bundleID): AppInfo =
    AppInfo(
        bundleID = bundleID,
        displayName = name,
        version = "1.0",
        shortVersion = "1.0",
        ipaSize = 1024L,
        iconData = null,
    )

internal fun fakeDevice(udid: String, name: String = "iPhone-$udid"): DeviceInfo =
    DeviceInfo(
        udid = udid,
        deviceName = name,
        productType = "iPhone16,1",
        productVersion = "18.0",
        buildVersion = "22A",
    )
