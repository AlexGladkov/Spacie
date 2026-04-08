package com.spacie.core.api

actual fun createPlatformDeviceService(): DeviceServiceApi = WindowsDeviceServiceImpl()
