package com.spacie.core

import com.spacie.core.error.SpacieError
import com.spacie.core.validation.InputValidator
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class InputValidatorTest {

    // MARK: - UDID Validation

    @Test
    fun validUDID_40HexChars_passes() {
        val udid = "00008110001A35E22EF8801E00008110001A35E2"
        val result = InputValidator.validateUDID(udid)
        assertEquals(udid, result)
    }

    @Test
    fun validUDID_networkFormat_passes() {
        // Wi-Fi/network pairing format: UUID-style with hyphens (36 chars)
        val udid = "00008110-001A-35E2-2EF8-801E00008110"
        val result = InputValidator.validateUDID(udid)
        assertEquals(udid, result)
    }

    @Test
    fun validUDID_25Chars_passes() {
        val udid = "00008110001A35E22EF8801E0"
        val result = InputValidator.validateUDID(udid)
        assertEquals(udid, result)
    }

    @Test
    fun invalidUDID_tooShort_throws() {
        val udid = "00008110001A35E22EF8"
        assertFailsWith<SpacieError.InvalidUDID> {
            InputValidator.validateUDID(udid)
        }
    }

    @Test
    fun invalidUDID_tooLong_throws() {
        val udid = "A".repeat(41)
        assertFailsWith<SpacieError.InvalidUDID> {
            InputValidator.validateUDID(udid)
        }
    }

    @Test
    fun invalidUDID_shellMetachars_throws() {
        val udid = "00008110001A35E22EF8801E;rm -rf /"
        assertFailsWith<SpacieError.InvalidUDID> {
            InputValidator.validateUDID(udid)
        }
    }

    @Test
    fun invalidUDID_empty_throws() {
        assertFailsWith<SpacieError.InvalidUDID> {
            InputValidator.validateUDID("")
        }
    }

    @Test
    fun validateUDID_returnsInputUnchanged() {
        val udid = "00008110001A35E22EF8801E00008110001A35E2"
        val result = InputValidator.validateUDID(udid)
        assertEquals(udid, result)
    }

    // MARK: - Bundle ID Validation

    @Test
    fun validBundleID_twoSegments_passes() {
        val result = InputValidator.validateBundleID("com.example")
        assertEquals("com.example", result)
    }

    @Test
    fun validBundleID_threeSegments_passes() {
        val result = InputValidator.validateBundleID("com.example.MyApp")
        assertEquals("com.example.MyApp", result)
    }

    @Test
    fun validBundleID_withHyphens_passes() {
        val result = InputValidator.validateBundleID("org.ietf.http-client")
        assertEquals("org.ietf.http-client", result)
    }

    @Test
    fun validBundleID_numeric_passes() {
        val result = InputValidator.validateBundleID("com.1password.1password")
        assertEquals("com.1password.1password", result)
    }

    @Test
    fun invalidBundleID_singleSegment_throws() {
        assertFailsWith<SpacieError.InvalidBundleID> {
            InputValidator.validateBundleID("MyApp")
        }
    }

    @Test
    fun invalidBundleID_leadingDot_throws() {
        assertFailsWith<SpacieError.InvalidBundleID> {
            InputValidator.validateBundleID(".com.example")
        }
    }

    @Test
    fun invalidBundleID_emptySegment_throws() {
        assertFailsWith<SpacieError.InvalidBundleID> {
            InputValidator.validateBundleID("com..example")
        }
    }

    @Test
    fun invalidBundleID_shellInjection_throws() {
        assertFailsWith<SpacieError.InvalidBundleID> {
            InputValidator.validateBundleID("com.example;cat /etc/passwd")
        }
    }

    @Test
    fun invalidBundleID_tooLong_throws() {
        // 160 characters -- over the 155-char limit
        val tooLong = "com." + "a".repeat(156)
        assertFailsWith<SpacieError.InvalidBundleID> {
            InputValidator.validateBundleID(tooLong)
        }
    }

    @Test
    fun validateBundleID_returnsInputUnchanged() {
        val bundleID = "com.example.MyApp"
        val result = InputValidator.validateBundleID(bundleID)
        assertEquals(bundleID, result)
    }

    // MARK: - Display Name Sanitization

    @Test
    fun sanitizeDisplayName_normalString_unchanged() {
        val name = "iPhone 15 Pro"
        assertEquals(name, InputValidator.sanitizeDisplayName(name, 255))
    }

    @Test
    fun sanitizeDisplayName_stripsControlChars() {
        val name = "Bad\u0001Name\u001F"
        val result = InputValidator.sanitizeDisplayName(name, 255)
        assertEquals("BadName", result)
    }

    @Test
    fun sanitizeDisplayName_preservesSpace() {
        val name = "Hello World"
        assertEquals("Hello World", InputValidator.sanitizeDisplayName(name, 255))
    }

    @Test
    fun sanitizeDisplayName_stripsBidiOverrides() {
        // U+202E = RLO (Right-to-Left Override)
        val name = "App\u202EName"
        val result = InputValidator.sanitizeDisplayName(name, 255)
        assertFalse(result.any { it.code == 0x202E })
        assertEquals("AppName", result)
    }

    @Test
    fun sanitizeDisplayName_stripsBidiIsolates() {
        // U+2066 = LRI
        val name = "App\u2066Name"
        val result = InputValidator.sanitizeDisplayName(name, 255)
        assertFalse(result.any { it.code == 0x2066 })
        assertEquals("AppName", result)
    }

    @Test
    fun sanitizeDisplayName_truncatesAtMaxLength() {
        val name = "x".repeat(300)
        val result = InputValidator.sanitizeDisplayName(name, 255)
        assertEquals(255, result.length)
    }

    @Test
    fun sanitizeDisplayName_exactlyMaxLength_notTruncated() {
        val name = "x".repeat(255)
        val result = InputValidator.sanitizeDisplayName(name, 255)
        assertEquals(255, result.length)
    }

    @Test
    fun sanitizeDisplayName_emptyString_returnsEmpty() {
        assertEquals("", InputValidator.sanitizeDisplayName("", 255))
    }

    // MARK: - Filename Sanitization

    @Test
    fun sanitizeFilename_normalString_unchanged() {
        val result = InputValidator.sanitizeFilename("My Cool App")
        assertEquals("My Cool App", result)
    }

    @Test
    fun sanitizeFilename_stripsPathSeparators() {
        val result = InputValidator.sanitizeFilename("../../etc/passwd")
        assertFalse(result.contains("/"))
        assertFalse(result.contains(".."))
    }

    @Test
    fun sanitizeFilename_emptyInput_returnsUntitled() {
        val result = InputValidator.sanitizeFilename("")
        assertEquals("Untitled", result)
    }

    @Test
    fun sanitizeFilename_allInvalidChars_returnsUntitled() {
        val result = InputValidator.sanitizeFilename("!@#\$%^&*()")
        assertEquals("Untitled", result)
    }

    @Test
    fun sanitizeFilename_truncatesLongNames() {
        val longName = "a".repeat(100)
        val result = InputValidator.sanitizeFilename(longName)
        assertTrue(result.length <= 50)
    }

    // MARK: - ScanExclusionRules

    @Test
    fun scanExclusionRules_excludesByBasename() {
        val rules = com.spacie.core.scanner.ScanExclusionRules(
            excludedBasenames = setOf("node_modules", ".git"),
            excludedPathPrefixes = emptyList()
        )
        assertTrue(rules.shouldExclude("node_modules", "/Users/test/project/node_modules"))
        assertTrue(rules.shouldExclude(".git", "/Users/test/project/.git"))
        assertFalse(rules.shouldExclude("src", "/Users/test/project/src"))
    }

    @Test
    fun scanExclusionRules_excludesByPathPrefix() {
        val rules = com.spacie.core.scanner.ScanExclusionRules(
            excludedBasenames = emptySet(),
            excludedPathPrefixes = listOf("/System/Volumes/Data")
        )
        assertTrue(rules.shouldExclude("Data", "/System/Volumes/Data"))
        assertTrue(rules.shouldExclude("subdir", "/System/Volumes/Data/subdir"))
        assertFalse(rules.shouldExclude("other", "/System/Volumes/VM"))
    }
}
