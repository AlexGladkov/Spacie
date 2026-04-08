package com.spacie.core.api

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Platform factory for [DeviceServiceApi].
 *
 * The implementation lives in macosMain where platform-specific
 * iMobileDevice tool invocation and plist parsing APIs are available.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaDeviceServiceFactory")
expect fun createPlatformDeviceService(): DeviceServiceApi
