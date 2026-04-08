package com.spacie.core.scanner

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Immutable set of rules for excluding directories during a file system scan.
 *
 * Two kinds of checks are performed:
 * 1. **Basename lookup** -- O(1) Set membership test against known directory names
 *    (e.g. `node_modules`, `.git`, `DerivedData`).
 * 2. **Path prefix match** -- linear scan over a small array of absolute path prefixes
 *    (e.g. `~/Library/Caches`).
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanExclusionRules")
class ScanExclusionRules(
    val excludedBasenames: Set<String>,
    val excludedPathPrefixes: List<String>
) {
    /**
     * Pre-computed `excludedPathPrefixes[i] + "/"` strings.
     * Avoids creating a temporary string on every [shouldExclude] call.
     */
    private val prefixesWithSlash: List<String> = excludedPathPrefixes.map { prefix ->
        if (prefix.endsWith("/")) prefix else "$prefix/"
    }

    /**
     * Returns `true` when the directory at [path] with the given [name] should
     * be skipped entirely (including its subtree).
     */
    fun shouldExclude(name: String, path: String): Boolean {
        if (excludedBasenames.contains(name)) {
            return true
        }
        for (i in excludedPathPrefixes.indices) {
            if (path == excludedPathPrefixes[i] || path.startsWith(prefixesWithSlash[i])) {
                return true
            }
        }
        return false
    }

    companion object {
        /** Default directory basenames excluded from scanning. */
        val defaultBasenames: Set<String> = setOf(
            // JavaScript / Node
            "node_modules", ".npm", ".yarn", ".pnpm-store",
            // Git
            ".git",
            // Kotlin / JVM
            ".konan", ".gradle", ".m2",
            // Xcode / Apple
            "DerivedData", "xcuserdata", ".swiftpm",
            // CocoaPods
            "Pods", ".cocoapods",
            // Rust
            ".cargo", ".rustup",
            // Python
            "__pycache__", ".venv", ".tox",
            // Swift Package Manager build
            ".build",
            // General caches
            ".cache", ".ccache",
            // Containers & VMs
            ".vagrant", ".docker",
            // Carthage
            "Carthage",
            // Dart / Flutter
            ".pub-cache"
        )

        /** Default absolute path prefixes excluded from scanning. */
        fun defaultPathPrefixes(home: String): List<String> = listOf(
            "/System/Volumes/Data",
            "/System/Volumes/VM",
            "/System/Volumes/Preboot",
            "/System/Volumes/Update",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",
            "$home/Library/Developer/Xcode/DerivedData",
            "/private/var/folders",
            "/private/var/db",
            "/private/tmp",
            "/tmp"
        )
    }
}
