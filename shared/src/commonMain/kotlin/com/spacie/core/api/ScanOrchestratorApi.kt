package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.flow.CommonStateFlow
import com.spacie.core.model.ScanConfiguration
import com.spacie.core.model.ScanPhase
import com.spacie.core.model.ScanProgress
import com.spacie.core.model.ScanStats
import com.spacie.core.model.SmartScanResult
import com.spacie.core.model.SmartScanSettings
import kotlin.coroutines.cancellation.CancellationException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanOrchestratorApi")
interface ScanOrchestratorApi {

    val phase: CommonStateFlow<ScanPhase>
    val progress: CommonStateFlow<ScanProgress?>
    val smartScanResult: CommonStateFlow<SmartScanResult?>

    @Throws(SpacieError::class, CancellationException::class)
    suspend fun startScan(configuration: ScanConfiguration): ScanStats?

    fun cancel()
    fun handleDeletion(deletedBytes: Long)
    fun setSmartScanSettings(settings: SmartScanSettings?)
}
