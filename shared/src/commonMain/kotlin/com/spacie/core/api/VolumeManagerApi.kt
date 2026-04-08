package com.spacie.core.api

import com.spacie.core.flow.CommonStateFlow
import com.spacie.core.model.VolumeInfo
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeManagerApi")
interface VolumeManagerApi {

    val volumes: CommonStateFlow<List<VolumeInfo>>

    fun refresh()
    fun startMonitoring()
    fun stopMonitoring()
}
