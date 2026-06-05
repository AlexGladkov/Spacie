package com.spacie.core.api

import com.spacie.core.error.SpacieError
import com.spacie.core.platform.HomebrewResolver
import com.spacie.core.platform.ProcessRunnerApi

/**
 * `brew install` orchestration for macOS dependency setup.
 *
 * Extracted from `DeviceServiceImpl` (Sprint 4.5 god-class split). Owns the
 * lifecycle of the package-manager-side concerns: probing for tool paths
 * (delegated to [HomebrewResolver]) and running `brew install` for missing
 * tools.
 */
internal class DependencyManagerMac(
    private val runner: ProcessRunnerApi,
    private val resolver: HomebrewResolver,
) : DependencyManagerApi {

    override suspend fun checkDependencies(): DependencyStatus = resolver.resolveAll()

    override suspend fun installDependencies(onLine: (String) -> Unit) {
        val brewPath = resolver.resolve("brew")
            ?: throw SpacieError.PackageManagerNotInstalled("Homebrew", "https://brew.sh")

        val result = runner.runWithLineOutput(
            executablePath = brewPath,
            arguments = listOf("install", "libimobiledevice", "ideviceinstaller", "ipatool"),
            timeoutSeconds = 300.0,
            onLine = onLine
        )

        if (result.exitCode != 0) {
            val stderr = result.stderr.decodeToString().trim()
            throw SpacieError.DependencyInstallFailed(
                if (stderr.isEmpty()) "Exit code ${result.exitCode}" else stderr
            )
        }

        resolver.invalidateCache()
    }
}
