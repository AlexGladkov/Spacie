package com.spacie.core.api.internal

import com.spacie.core.api.DependencyStatus
import com.spacie.core.error.SpacieError
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class DeviceServiceHelpersTest {

    @Test
    fun parseProgressLine_extractsPercent() {
        assertEquals(0.0, DeviceServiceHelpers.parseProgressLine("0% done"))
        assertEquals(0.5, DeviceServiceHelpers.parseProgressLine("Progress: 50%"))
        assertEquals(0.425, DeviceServiceHelpers.parseProgressLine("[==> ] 42.5 %"))
        assertEquals(1.0, DeviceServiceHelpers.parseProgressLine("100%"))
        // Clamped: never above 1.0
        assertEquals(1.0, DeviceServiceHelpers.parseProgressLine("Done 250% overcomplete"))
    }

    @Test
    fun parseProgressLine_noPercent_returnsNull() {
        assertNull(DeviceServiceHelpers.parseProgressLine("Installing libimobiledevice..."))
        assertNull(DeviceServiceHelpers.parseProgressLine(""))
    }

    @Test
    fun parseKeyValueOutput_parsesIdeviceInfoStyle() {
        val out = """
            DeviceName: iPhone Artyom
            ProductType: iPhone16,1
            ProductVersion: 18.3.1
            BuildVersion: 22D72
            EmptyLine:
            : missingKey
            malformedNoColon
        """.trimIndent()

        val parsed = DeviceServiceHelpers.parseKeyValueOutput(out)

        assertEquals("iPhone Artyom", parsed["DeviceName"])
        assertEquals("iPhone16,1", parsed["ProductType"])
        assertEquals("18.3.1", parsed["ProductVersion"])
        assertEquals("22D72", parsed["BuildVersion"])
        assertEquals("", parsed["EmptyLine"])
        // ": missingKey" → empty key, skipped
        assertTrue(parsed.keys.none { it.isEmpty() })
        // "malformedNoColon" → no colon, skipped
        assertTrue("malformedNoColon" !in parsed)
    }

    @Test
    fun stripANSI_removesColourCodes() {
        // ESC[1;32m + text + ESC[0m
        val coloured = "[1;32mSUCCESS[0m: Done"
        assertEquals("SUCCESS: Done", DeviceServiceHelpers.stripANSI(coloured))

        // Plain text unchanged
        assertEquals("plain text", DeviceServiceHelpers.stripANSI("plain text"))
    }

    @Test
    fun statusToErrorOrNull_mapsCorrectly() {
        assertNull(
            DeviceServiceHelpers.statusToErrorOrNull(DependencyStatus.Ready(mapOf("brew" to "/x")))
        )

        val missing = DeviceServiceHelpers.statusToErrorOrNull(
            DependencyStatus.Missing(listOf("idevice_id"))
        )
        assertTrue(missing is SpacieError.DependencyMissing)
        assertEquals(listOf("idevice_id"), (missing).tools)

        val pkgMissing = DeviceServiceHelpers.statusToErrorOrNull(
            DependencyStatus.PackageManagerMissing("Homebrew", "https://brew.sh")
        )
        assertTrue(pkgMissing is SpacieError.PackageManagerNotInstalled)
    }

    @Test
    fun jsonStringLiteral_escapesSpecialChars() {
        assertEquals("\"hello\"", DeviceServiceHelpers.jsonStringLiteral("hello"))
        assertEquals(
            "\"with \\\"quotes\\\" and \\\\ slash\"",
            DeviceServiceHelpers.jsonStringLiteral("with \"quotes\" and \\ slash")
        )
        assertEquals("\"line1\\nline2\"", DeviceServiceHelpers.jsonStringLiteral("line1\nline2"))
        // Tab + control char
        assertEquals(
            "\"a\\tb\\u0001c\"",
            DeviceServiceHelpers.jsonStringLiteral("a\tbc")
        )
    }
}
