package com.spacie.core.api

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeManagerFactory")
actual fun createPlatformVolumeManager(): VolumeManagerApi = VolumeManagerImpl()
