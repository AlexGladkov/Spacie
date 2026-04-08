package com.spacie.core.api

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Platform factory for [VolumeManagerApi].
 *
 * The implementation lives in macosMain where platform-specific
 * volume enumeration APIs (NSFileManager, NSWorkspace) are available.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaVolumeManagerFactory")
expect fun createPlatformVolumeManager(): VolumeManagerApi
