package com.spacie.core.platform

expect fun homeDirectory(): String
expect fun pathExists(path: String): Boolean
expect fun cacheDirectory(): String
