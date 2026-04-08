package com.spacie.core.platform

import com.spacie.core.api.DependencyStatus
import java.io.File

/**
 * Resolves iMobileDevice tool paths on Windows by probing:
 * 1. Chocolatey bin directory (C:\ProgramData\chocolatey\bin\)
 * 2. Scoop shims (~\scoop\shims\)
 * 3. Common manual installation paths
 * 4. All entries on the system PATH
 *
 * On non-Windows platforms this resolver falls through PATH probing,
 * making it safe to instantiate on any JVM target.
 */
class ChocolateyResolver {

    private val probePaths: List<String> by lazy {
        buildList {
            add("C:\\ProgramData\\chocolatey\\bin")
            add(System.getProperty("user.home") + "\\scoop\\shims")
            add("C:\\Program Files\\libimobiledevice")
            add("C:\\Program Files (x86)\\libimobiledevice")
            addAll(
                System.getenv("PATH").orEmpty().split(File.pathSeparator).filter { it.isNotBlank() }
            )
        }
    }

    private val requiredTools = listOf(
        "idevice_id",
        "ideviceinfo",
        "ideviceinstaller",
        "idevicepair",
        "ipatool"
    )

    // Windows executables carry a .exe suffix; probe with and without for portability
    private val execExtensions: List<String> =
        if (isWindows()) listOf(".exe", "") else listOf("", ".exe")

    private val cache = HashMap<String, String?>()

    /**
     * Resolve the absolute path for [toolName] by probing known locations.
     *
     * @return absolute path string or null if the tool cannot be found
     */
    fun resolve(toolName: String): String? {
        if (cache.containsKey(toolName)) return cache[toolName]
        val resolved = probeToolOnDisk(toolName)
        cache[toolName] = resolved
        return resolved
    }

    /** Returns true when Chocolatey itself appears to be installed. */
    fun isChocolateyInstalled(): Boolean =
        File("C:\\ProgramData\\chocolatey\\bin\\choco.exe").exists() ||
                probeToolOnDisk("choco") != null

    /**
     * Resolve all required tools and return the aggregate dependency status.
     *
     * [DependencyStatus.HomebrewMissing] is returned when no package manager
     * (Chocolatey / Scoop) can be detected — semantically analogous to the
     * macOS case where Homebrew is absent.
     */
    fun resolveAll(): DependencyStatus {
        val chocoPath = resolve("choco")
        if (chocoPath == null && !isChocolateyInstalled()) {
            return DependencyStatus.HomebrewMissing
        }

        val missing = mutableListOf<String>()
        val paths = mutableMapOf<String, String>()
        chocoPath?.let { paths["choco"] = it }

        for (tool in requiredTools) {
            val path = resolve(tool)
            if (path != null) paths[tool] = path
            else missing.add(tool)
        }

        return if (missing.isNotEmpty()) DependencyStatus.Missing(missing)
        else DependencyStatus.Ready(paths)
    }

    /** Invalidate all cached paths, forcing re-probing on next access. */
    fun invalidateCache() = cache.clear()

    private fun probeToolOnDisk(toolName: String): String? {
        for (dir in probePaths) {
            if (dir.isBlank()) continue
            for (ext in execExtensions) {
                val candidate = File(dir, "$toolName$ext")
                if (candidate.exists() && candidate.canExecute()) return candidate.absolutePath
            }
        }
        return null
    }

    private fun isWindows(): Boolean =
        System.getProperty("os.name").orEmpty().contains("Windows", ignoreCase = true)
}
