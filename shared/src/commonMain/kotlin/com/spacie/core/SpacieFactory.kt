package com.spacie.core

import com.spacie.core.api.DeviceServiceApi
import com.spacie.core.api.VolumeManagerApi
import com.spacie.core.api.createPlatformDeviceService
import com.spacie.core.api.createPlatformVolumeManager
import com.spacie.core.model.ScanProfileType
import com.spacie.core.platform.PermissionChecker
import com.spacie.core.platform.ProcessRunner
import com.spacie.core.platform.TrashService
import com.spacie.core.scanner.ScanExclusionRules
import com.spacie.core.scanner.ScanProfile
import com.spacie.core.validation.InputValidator
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSpacieFactory")
object SpacieFactory {

    val version: String = "1.0.0"
    val sdkName: String = "SpacieKit"

    fun createInputValidator(): InputValidator = InputValidator

    fun createScanExclusionRules(
        basenames: List<String>,
        pathPrefixes: List<String>
    ): ScanExclusionRules = ScanExclusionRules(basenames.toSet(), pathPrefixes)

    fun defaultScanProfilePaths(profileType: ScanProfileType): List<String> =
        ScanProfile.tier1Paths(profileType)

    fun createProcessRunner(): ProcessRunner = ProcessRunner()

    fun createTrashService(): TrashService = TrashService()

    fun createPermissionChecker(): PermissionChecker = PermissionChecker()

    fun createVolumeManager(): VolumeManagerApi = createPlatformVolumeManager()

    fun createDeviceService(): DeviceServiceApi = createPlatformDeviceService()
}
