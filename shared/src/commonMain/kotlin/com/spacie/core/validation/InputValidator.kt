package com.spacie.core.validation

import com.spacie.core.error.SpacieError
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Sanitises inputs originating from iOS devices and user text fields before
 * they are used in shell commands, file paths, or UI labels.
 *
 * All methods are pure functions with no side effects and no internal state.
 *
 * Security note: All validation is performed via manual character inspection
 * (no regex) to prevent ReDoS attacks.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaInputValidator")
object InputValidator {

    // -- Constants --

    private const val UDID_MIN_LENGTH = 25
    private const val UDID_MAX_LENGTH = 40
    private const val MAX_BUNDLE_ID_LENGTH = 155
    private const val MAX_FILENAME_LENGTH = 50

    // -- UDID Validation --

    /**
     * Validates that a UDID string contains only hex digits and hyphens
     * and falls within the expected length range (25-40 characters).
     *
     * @param udid The raw UDID string from the device.
     * @return The validated UDID string (unchanged).
     * @throws SpacieError.InvalidUDID if the format does not match.
     */
    @Throws(SpacieError::class)
    fun validateUDID(udid: String): String {
        if (udid.length < UDID_MIN_LENGTH || udid.length > UDID_MAX_LENGTH) {
            throw SpacieError.InvalidUDID(udid)
        }
        for (ch in udid) {
            if (!isHexDigit(ch) && ch != '-') {
                throw SpacieError.InvalidUDID(udid)
            }
        }
        return udid
    }

    // -- Bundle ID Validation --

    /**
     * Validates that a bundle identifier is a well-formed reverse-DNS
     * string with at least two segments.
     *
     * Valid: "com.example.MyApp", "org.ietf.http-client"
     * Invalid: "MyApp" (single segment), ".com.example" (leading dot)
     *
     * @param bundleID The raw bundle identifier.
     * @return The validated bundle identifier (unchanged).
     * @throws SpacieError.InvalidBundleID on failure.
     */
    @Throws(SpacieError::class)
    fun validateBundleID(bundleID: String): String {
        if (bundleID.length > MAX_BUNDLE_ID_LENGTH) {
            throw SpacieError.InvalidBundleID(bundleID)
        }
        val segments = bundleID.split('.')
        if (segments.size < 2) {
            throw SpacieError.InvalidBundleID(bundleID)
        }
        for (segment in segments) {
            if (!isValidBundleIDSegment(segment)) {
                throw SpacieError.InvalidBundleID(bundleID)
            }
        }
        return bundleID
    }

    // -- Display Name Sanitization --

    /**
     * Sanitises a device or app display name for safe rendering in the UI.
     *
     * Removes control characters (U+0000..U+001F except U+0020 space),
     * bidirectional overrides (U+202A..U+202E), and bidirectional isolates
     * (U+2066..U+2069). Truncates to [maxLength] characters.
     *
     * @param name The raw display name.
     * @param maxLength Maximum allowed character count (default 255).
     * @return A sanitised copy of the name.
     */
    fun sanitizeDisplayName(name: String, maxLength: Int): String {
        val builder = StringBuilder(name.length)
        for (char in name) {
            val code = char.code
            // Keep regular space (U+0020)
            if (code == 0x0020) {
                builder.append(char)
                continue
            }
            // Drop control characters U+0000..U+001F
            if (code in 0x0000..0x001F) continue
            // Drop bidi overrides U+202A..U+202E
            if (code in 0x202A..0x202E) continue
            // Drop bidi isolates U+2066..U+2069
            if (code in 0x2066..0x2069) continue

            builder.append(char)
        }
        val cleaned = builder.toString()
        return if (cleaned.length <= maxLength) cleaned else cleaned.substring(0, maxLength)
    }

    // -- Filename Sanitization --

    /**
     * Strips all characters outside the filename whitelist and truncates.
     * If the input is empty or becomes empty after filtering, falls back to "Untitled".
     *
     * Allowed characters: a-z A-Z 0-9 space . _ -
     *
     * @param name The raw display name.
     * @return A filesystem-safe filename (without extension).
     */
    fun sanitizeFilename(name: String): String {
        val builder = StringBuilder(minOf(name.length, MAX_FILENAME_LENGTH))
        for (char in name) {
            if (isFilenameAllowed(char)) {
                builder.append(char)
                if (builder.length >= MAX_FILENAME_LENGTH) break
            }
        }
        if (builder.isEmpty()) return "Untitled"

        // Remove leading/trailing whitespace and dots for extra safety
        var result = builder.toString().trim()
        result = result.trimStart('.')
        result = result.trimEnd('.')
        return result.ifEmpty { "Untitled" }
    }

    // -- Private Helpers --

    private fun isHexDigit(ch: Char): Boolean {
        return ch in '0'..'9' || ch in 'a'..'f' || ch in 'A'..'F'
    }

    private fun isValidBundleIDSegment(segment: String): Boolean {
        if (segment.isEmpty()) return false
        val first = segment[0]
        if (!first.isLetterOrDigit() || !first.isAsciiAlphanumeric()) return false
        if (segment.length == 1) return true
        val last = segment[segment.length - 1]
        if (!last.isAsciiAlphanumeric()) return false
        for (i in 1 until segment.length - 1) {
            val ch = segment[i]
            if (!ch.isAsciiAlphanumeric() && ch != '-') return false
        }
        return true
    }

    private fun Char.isAsciiAlphanumeric(): Boolean {
        return this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9'
    }

    private fun isFilenameAllowed(ch: Char): Boolean {
        return ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9'
                || ch == ' ' || ch == '.' || ch == '_' || ch == '-'
    }
}
