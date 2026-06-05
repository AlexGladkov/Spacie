package com.spacie.core.api

import com.spacie.core.platform.ProcessRunnerApi
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceFactory")
actual fun createPlatformDeviceService(runner: ProcessRunnerApi): DeviceServiceApi =
    DeviceServiceImpl(runner = runner)
