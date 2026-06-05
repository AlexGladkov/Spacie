package com.spacie.core.api.internal

import com.spacie.core.api.DependencyStatus
import com.spacie.core.error.SpacieError
import com.spacie.core.platform.HomebrewResolver

/**
 * Thin wrapper around [HomebrewResolver] that turns a missing tool / package
 * manager into the typed [SpacieError]. Extracted from `DeviceServiceImpl`
 * (Sprint 4.5 god-class split) so all sub-clients ([IpaToolClient],
 * [IDeviceClient], [DependencyManagerMac], [TransferOrchestrator]) share one
 * dependency-resolution implementation instead of re-deriving it.
 */
internal open class ToolPaths(private val resolver: HomebrewResolver) {

    /**
     * Snapshot of all resolved tool paths.
     * @throws SpacieError.DependencyMissing if any required tool is missing.
     * @throws SpacieError.PackageManagerNotInstalled if Homebrew itself is missing.
     */
    open fun all(): Map<String, String> {
        return when (val status = resolver.resolveAll()) {
            is DependencyStatus.Ready -> status.toolPaths
            is DependencyStatus.Missing -> throw SpacieError.DependencyMissing(status.tools)
            is DependencyStatus.PackageManagerMissing ->
                throw SpacieError.PackageManagerNotInstalled(status.managerName, status.installUrl)
        }
    }

    /** Lookup one tool by name; throws [SpacieError.DependencyMissing] when absent. */
    open fun require(tool: String): String =
        all()[tool] ?: throw SpacieError.DependencyMissing(listOf(tool))

    /**
     * Lookup one tool without throwing on the documented `tool-missing` path
     * (returns null). Other Throwables (OOM, native crashes, programmer
     * errors) are intentionally NOT swallowed — re-thrown so the caller can
     * crash visibly instead of mistaking a real fault for "tool not
     * installed" and silently falling back.
     */
    open fun optional(tool: String): String? =
        try {
            all()[tool]
        } catch (e: SpacieError.DependencyMissing) {
            null
        } catch (e: SpacieError.PackageManagerNotInstalled) {
            null
        }
}
