package com.spacie.core.api

import com.spacie.core.platform.ProcessRunnerApi

actual fun createPlatformDeviceService(runner: ProcessRunnerApi): DeviceServiceApi =
    WindowsDeviceServiceImpl(runner = runner)
