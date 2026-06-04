package com.spacie.core.api.internal

import com.spacie.core.api.DependencyStatus
import com.spacie.core.error.SpacieError

/**
 * Internal helpers shared between `DeviceServiceImpl` (macOS) and
 * `WindowsDeviceServiceImpl` (Windows). Extracted to commonMain so the two
 * service implementations stop drifting — the audit found ~70% duplication
 * with subtle parsing differences across the two.
 *
 * These functions are pure (no platform dependencies), so they live safely
 * in commonMain.
 */
internal object DeviceServiceHelpers {

    private val PROGRESS_REGEX = Regex("""(\d+(?:\.\d+)?)\s*%""")
    // ESC ('') is the leading byte of every CSI (control-sequence
    // introducer) ANSI escape. Strips colour codes from coloured CLI output
    // such as `ipatool`'s default text format.
    private val ANSI_REGEX = Regex("\\[[0-9;]*[mGKHFJA-Z]")

    /**
     * Parse a `42.5%`-style progress token out of an arbitrary line.
     * Returns null when the line does not contain a percent token; clamps
     * to `[0.0, 1.0]`.
     */
    fun parseProgressLine(line: String): Double? {
        val match = PROGRESS_REGEX.find(line) ?: return null
        val raw = match.groupValues[1].toDoubleOrNull() ?: return null
        return minOf(1.0, raw / 100.0)
    }

    /**
     * Parse `Key: Value` output produced by `ideviceinfo` and similar tools.
     * Empty/malformed lines are ignored.
     */
    fun parseKeyValueOutput(output: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        for (line in output.split("\n")) {
            val idx = line.indexOf(':')
            if (idx <= 0) continue
            val key = line.substring(0, idx).trim()
            val value = line.substring(idx + 1).trim()
            if (key.isNotEmpty()) result[key] = value
        }
        return result
    }

    /** Strip CSI ANSI escape sequences from CLI output. */
    fun stripANSI(text: String): String = text.replace(ANSI_REGEX, "")

    /**
     * Convert a [DependencyStatus] to the matching [SpacieError], or null
     * when the status is [DependencyStatus.Ready]. Centralises the if/else
     * cascade previously duplicated across both platform services.
     */
    fun statusToErrorOrNull(status: DependencyStatus): SpacieError? = when (status) {
        is DependencyStatus.Ready -> null
        is DependencyStatus.Missing -> SpacieError.DependencyMissing(status.tools)
        is DependencyStatus.PackageManagerMissing ->
            SpacieError.PackageManagerNotInstalled(status.managerName, status.installUrl)
    }

    /**
     * Escape [value] for inclusion as a JSON string literal (the returned
     * string includes the surrounding quotes). Used to build the archive
     * `metadata.json` without pulling in `kotlinx-serialization`.
     */
    fun jsonStringLiteral(value: String): String {
        val sb = StringBuilder(value.length + 2)
        sb.append('"')
        for (ch in value) {
            when (ch) {
                '\\' -> sb.append("\\\\")
                '"' -> sb.append("\\\"")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                else -> if (ch.code < 0x20) {
                    sb.append("\\u")
                    sb.append(ch.code.toString(16).padStart(4, '0'))
                } else {
                    sb.append(ch)
                }
            }
        }
        sb.append('"')
        return sb.toString()
    }
}
