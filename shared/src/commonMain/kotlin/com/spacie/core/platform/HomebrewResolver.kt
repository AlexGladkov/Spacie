package com.spacie.core.platform

import com.spacie.core.api.DependencyStatus
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Resolves Homebrew tool paths on macOS by probing known installation prefixes.
 *
 * This class is pure commonMain code -- it relies only on [pathExists] from PlatformPaths.
 * Tool resolution results are cached for the lifetime of the resolver instance
 * (or until [invalidateCache] is called).
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaHomebrewResolver")
class HomebrewResolver {

    private val prefixes = listOf("/opt/homebrew/bin", "/usr/local/bin")

    private val requiredTools = listOf(
        "idevice_id",
        "ideviceinfo",
        "ideviceinstaller",
        "idevicepair",
        "ipatool"
    )

    private val cache = HashMap<String, String?>()

    /**
     * Resolve the absolute path for a tool by probing known Homebrew prefixes.
     *
     * @param toolName the CLI tool name (e.g. "brew", "idevice_id")
     * @return the absolute path to the executable, or null if not found
     */
    fun resolve(toolName: String): String? {
        if (cache.containsKey(toolName)) return cache[toolName]
        val resolved = probeToolOnDisk(toolName)
        cache[toolName] = resolved
        return resolved
    }

    /**
     * Check whether Homebrew itself is installed.
     */
    fun isHomebrewInstalled(): Boolean = resolve("brew") != null

    /**
     * Resolve all required tools and return the overall dependency status.
     *
     * @return [DependencyStatus.Ready] with a map of tool paths when everything is available,
     *         [DependencyStatus.Missing] listing the missing tools,
     *         or [DependencyStatus.HomebrewMissing] if Homebrew is not found.
     */
    fun resolveAll(): DependencyStatus {
        val brewPath = resolve("brew")
            ?: return DependencyStatus.PackageManagerMissing("Homebrew", "https://brew.sh")

        val missing = mutableListOf<String>()
        val paths = mutableMapOf<String, String>()
        paths["brew"] = brewPath

        for (tool in requiredTools) {
            val path = resolve(tool)
            if (path != null) {
                paths[tool] = path
            } else {
                missing.add(tool)
            }
        }

        return if (missing.isNotEmpty()) {
            DependencyStatus.Missing(missing)
        } else {
            DependencyStatus.Ready(paths)
        }
    }

    /**
     * Invalidate all cached resolution results, forcing re-probing on next access.
     */
    fun invalidateCache() {
        cache.clear()
    }

    private fun probeToolOnDisk(toolName: String): String? {
        for (prefix in prefixes) {
            val candidate = "$prefix/$toolName"
            if (pathExists(candidate)) return candidate
        }
        return null
    }
}
