package com.spacie.core

import com.spacie.core.api.DeviceServiceApi
import com.spacie.core.api.VolumeManagerApi
import com.spacie.core.api.createPlatformDeviceService
import com.spacie.core.api.createPlatformVolumeManager
import com.spacie.core.model.ScanProfileType
import com.spacie.core.platform.PermissionChecker
import com.spacie.core.platform.ProcessRunner
import com.spacie.core.platform.ProcessRunnerApi
import com.spacie.core.platform.TrashService
import com.spacie.core.scanner.ScanExclusionRules
import com.spacie.core.scanner.ScanProfile
import com.spacie.core.validation.InputValidator
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Top-level entry point for assembling Spacie KMP services.
 *
 * Production code (Swift / Compose Desktop) keeps the historical call style:
 *
 * ```swift
 * SpaSpacieFactory.shared.createDeviceService()
 * ```
 *
 * Tests use [createDeviceServiceWith] to inject a custom [ProcessRunnerApi]
 * (e.g. `FakeProcessRunner`) and exercise [DeviceServiceApi] without spawning
 * real binaries.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSpacieFactory")
object SpacieFactory {

    const val version: String = "1.0.0"
    const val sdkName: String = "SpacieKit"

    fun createInputValidator(): InputValidator = InputValidator

    fun createScanExclusionRules(
        basenames: List<String>,
        pathPrefixes: List<String>
    ): ScanExclusionRules = ScanExclusionRules(basenames.toSet(), pathPrefixes)

    fun defaultScanProfilePaths(profileType: ScanProfileType): List<String> =
        ScanProfile.tier1Paths(profileType)

    fun createProcessRunner(): ProcessRunnerApi = ProcessRunner()

    fun createTrashService(): TrashService = TrashService()

    fun createPermissionChecker(): PermissionChecker = PermissionChecker()

    fun createVolumeManager(): VolumeManagerApi = createPlatformVolumeManager()

    /** Production: uses the platform [ProcessRunner]. */
    fun createDeviceService(): DeviceServiceApi =
        createPlatformDeviceService(ProcessRunner())

    /**
     * Test / preview override: build a [DeviceServiceApi] with a custom runner.
     *
     * Allows commonTest-side fakes (e.g. `FakeProcessRunner`) to drive the same
     * code path the production service uses.
     */
    fun createDeviceServiceWith(runner: ProcessRunnerApi): DeviceServiceApi =
        createPlatformDeviceService(runner)
}
