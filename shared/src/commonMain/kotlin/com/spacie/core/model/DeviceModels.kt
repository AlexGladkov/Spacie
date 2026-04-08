package com.spacie.core.model

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

// MARK: - DeviceInfo

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceInfo")
data class DeviceInfo(
    val udid: String,
    val deviceName: String,
    val productType: String,
    val productVersion: String,
    val buildVersion: String
) {
    val id: String get() = udid
}

// MARK: - AppInfo

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaAppInfo")
data class AppInfo(
    val bundleID: String,
    val displayName: String,
    val version: String,
    val shortVersion: String,
    val ipaSize: Long?,
    val iconData: ByteArray?
) {
    val id: String get() = bundleID

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is AppInfo) return false
        return bundleID == other.bundleID
    }

    override fun hashCode(): Int = bundleID.hashCode()
}

// MARK: - TrustState

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTrustState")
enum class TrustState {
    NOT_TRUSTED,
    DIALOG_SHOWN,
    TRUSTED
}

// MARK: - DeviceEvent

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceEvent")
sealed class DeviceEvent {
    @ObjCName("SpaDeviceEventConnected")
    data class Connected(val device: DeviceInfo) : DeviceEvent()

    @ObjCName("SpaDeviceEventDisconnected")
    data class Disconnected(val udid: String) : DeviceEvent()

    @ObjCName("SpaDeviceEventTrustStateChanged")
    data class TrustStateChanged(val udid: String, val state: TrustState) : DeviceEvent()

    @ObjCName("SpaDeviceEventError")
    data class Error(val message: String) : DeviceEvent()
}

// MARK: - TransferPhase

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTransferPhase")
enum class TransferPhase {
    PENDING,
    EXTRACTING,
    ARCHIVING,
    INSTALLING,
    COMPLETED,
    FAILED
}

// MARK: - TransferItem

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTransferItem")
data class TransferItem(
    val id: String,
    val app: AppInfo,
    val phase: TransferPhase,
    val progress: Double,
    val errorMessage: String?
)

// MARK: - TransferProgress

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTransferProgress")
data class TransferProgress(
    val items: List<TransferItem>,
    val currentItemIndex: Int
) {
    val completedCount: Int
        get() = items.count { it.phase == TransferPhase.COMPLETED }

    val failedCount: Int
        get() = items.count { it.phase == TransferPhase.FAILED }

    val totalCount: Int get() = items.size

    val overallProgress: Double
        get() {
            if (totalCount <= 0) return 0.0
            return (completedCount + failedCount).toDouble() / totalCount.toDouble()
        }
}

// MARK: - TransferItemResult

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTransferItemResult")
data class TransferItemResult(
    val id: String,
    val app: AppInfo,
    val success: Boolean,
    val archivedPath: String?,
    val errorMessage: String?
)

// MARK: - TransferResult

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTransferResult")
data class TransferResult(
    val items: List<TransferItemResult>
) {
    val successCount: Int
        get() = items.count { it.success }

    val failureCount: Int
        get() = items.count { !it.success }
}

// MARK: - ArchivedAppMetadata

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaArchivedAppMetadata")
data class ArchivedAppMetadata(
    val bundleID: String,
    val displayName: String,
    val version: String,
    val shortVersion: String,
    val ipaSize: Long,
    val archivedAt: Long,
    val sourceDeviceName: String?,
    val sourceDeviceVersion: String?
)

// MARK: - ArchivedApp

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaArchivedApp")
data class ArchivedApp(
    val id: String,
    val metadata: ArchivedAppMetadata,
    val ipaPath: String,
    val iconData: ByteArray?
) {
    val displayName: String get() = metadata.displayName
    val bundleID: String get() = metadata.bundleID

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ArchivedApp) return false
        return id == other.id
    }

    override fun hashCode(): Int = id.hashCode()
}
