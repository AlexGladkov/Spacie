package com.spacie.core.scanner

import com.spacie.core.model.ScanProfileType
import com.spacie.core.platform.homeDirectory
import com.spacie.core.platform.pathExists
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Provides predefined Tier 1 directory paths for Smart Scan prioritization.
 *
 * Each [ScanProfileType] maps to a curated list of known "heavy" directories
 * on macOS. These paths are scanned first during Phase 2, before falling back
 * to Tier 2 (remaining directories sorted by cached size or entry count).
 *
 * Non-existent paths are filtered out automatically.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaScanProfile")
object ScanProfile {

    /**
     * Returns filtered Tier 1 paths for the given profile type.
     *
     * Paths are expanded using [homeDirectory] and filtered
     * to include only those that exist on disk via [pathExists].
     *
     * @param profileType The active scan profile.
     * @return Array of absolute path strings that exist on the current system.
     */
    fun tier1Paths(profileType: ScanProfileType): List<String> {
        val candidates = when (profileType) {
            ScanProfileType.DEFAULT -> defaultPaths()
            ScanProfileType.DEVELOPER -> defaultPaths() + developerPaths()
        }
        return candidates.filter { pathExists(it) }
    }

    // -- Private Path Definitions --

    private fun defaultPaths(): List<String> {
        val home = homeDirectory()
        return listOf(
            "$home/Library/Caches",
            "$home/Library/Application Support",
            "$home/Library/Containers",
            "$home/Library/Group Containers",
            "$home/Library/Mail",
            "$home/Library/Messages",
            "$home/Downloads",
            "$home/Documents",
            "$home/Desktop",
            "$home/Movies",
            "$home/Music",
            "$home/Pictures",
            "/Applications",
            "/Library/Caches",
            "/System/Library",
            "/private/var"
        )
    }

    private fun developerPaths(): List<String> {
        val home = homeDirectory()
        return listOf(
            // Xcode
            "$home/Library/Developer/Xcode/DerivedData",
            "$home/Library/Developer/Xcode/Archives",
            "$home/Library/Developer/Xcode/iOS DeviceSupport",
            "$home/Library/Developer/CoreSimulator",
            // Android
            "$home/Library/Android/sdk",
            // Package managers & toolchains
            "$home/.gradle",
            "$home/.cocoapods",
            "$home/.pub-cache",
            "$home/.cargo",
            "$home/.rustup",
            "$home/.npm",
            "$home/.yarn",
            "$home/.pnpm-store",
            // Homebrew (Intel + ARM)
            "/usr/local/Cellar",
            "/opt/homebrew/Cellar",
            // Docker Desktop
            "$home/Library/Application Support/Docker/Data"
        )
    }
}
