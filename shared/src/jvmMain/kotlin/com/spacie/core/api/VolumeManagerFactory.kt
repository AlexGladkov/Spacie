package com.spacie.core.api

actual fun createPlatformVolumeManager(): VolumeManagerApi = JvmVolumeManagerImpl()
