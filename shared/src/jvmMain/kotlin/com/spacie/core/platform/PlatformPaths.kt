package com.spacie.core.platform

import java.io.File

actual fun homeDirectory(): String = System.getProperty("user.home") ?: "."

actual fun pathExists(path: String): Boolean = File(path).exists()

actual fun cacheDirectory(): String {
    val os = System.getProperty("os.name").orEmpty().lowercase()
    val home = homeDirectory()
    return when {
        os.contains("win") -> System.getenv("LOCALAPPDATA") ?: "$home\\AppData\\Local"
        os.contains("mac") -> "$home/Library/Caches"
        else -> System.getenv("XDG_CACHE_HOME") ?: "$home/.cache"
    }
}
