package com.spacie.core.api

import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.error.SpacieError
import com.spacie.core.platform.HomebrewResolver

/**
 * Test-only [ToolPaths] subclass with a fixed in-memory tool map.
 * Avoids hitting the real Homebrew resolver during unit tests.
 */
internal class StubToolPaths(private val map: Map<String, String>) :
    ToolPaths(HomebrewResolver()) {
    override fun all(): Map<String, String> = map
    override fun require(tool: String): String = map[tool]
        ?: throw SpacieError.DependencyMissing(listOf(tool))
    override fun optional(tool: String): String? = map[tool]
}
