package com.spacie.core.api

import com.spacie.core.platform.ProcessRunnerApi
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Platform factory for [DeviceServiceApi].
 *
 * The implementation lives in macosMain / jvmMain where platform-specific
 * iMobileDevice tool invocation and plist parsing APIs are available.
 *
 * @param runner the [ProcessRunnerApi] to inject into the service. Defaults to
 *   the platform [com.spacie.core.platform.ProcessRunner] when omitted.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceFactory")
expect fun createPlatformDeviceService(runner: ProcessRunnerApi): DeviceServiceApi
