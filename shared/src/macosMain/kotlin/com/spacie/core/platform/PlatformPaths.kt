package com.spacie.core.platform

import platform.Foundation.NSFileManager
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSSearchPathForDirectoriesInDomains
import platform.Foundation.NSCachesDirectory
import platform.Foundation.NSUserDomainMask

actual fun homeDirectory(): String = NSHomeDirectory()

actual fun pathExists(path: String): Boolean =
    NSFileManager.defaultManager.fileExistsAtPath(path)

actual fun cacheDirectory(): String =
    (NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, true
    ).firstOrNull() as? String) ?: "${homeDirectory()}/Library/Caches"
