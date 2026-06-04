package com.spacie.core.api

import com.spacie.core.api.internal.DeviceServiceHelpers
import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.error.SpacieError
import com.spacie.core.platform.ProcessRunnerApi
import com.spacie.core.platform.pathExists
import com.spacie.core.validation.InputValidator

/**
 * Wraps `ipatool` CLI commands: Apple ID session info, login, IPA download.
 *
 * Extracted from `DeviceServiceImpl` (Sprint 4.5 god-class split) so the
 * authentication concern lives apart from libimobiledevice tool orchestration.
 * Tests inject a `FakeProcessRunner` to exercise the redaction + 2FA-keyword
 * branches without spawning real binaries.
 *
 * ## Security
 * `ipatool auth login` requires `-p PASSWORD` in argv. That residual exposure
 * is documented at the [loginAppleID] call site. Mitigations applied:
 *  - Password redacted from any error output via [redactSecret].
 *  - Password never logged.
 *  - Process forcibly terminated on cancellation/timeout (ProcessRunner).
 */
internal class IpaToolClient(
    private val runner: ProcessRunnerApi,
    private val paths: ToolPaths,
) : AppleIDAuthApi {

    /**
     * `ipatool auth info` — exit 0 means the keychain still holds a valid token.
     * Swallows all errors → returns `false` (we treat unknown state as not authed).
     */
    override suspend fun checkAppleIDAuth(): Boolean {
        val ipatool = paths.optional("ipatool") ?: return false
        return try {
            runner.run(
                executablePath = ipatool,
                arguments = listOf("auth", "info"),
                timeoutSeconds = 10.0
            ).exitCode == 0
        } catch (_: Exception) {
            false
        }
    }

    /**
     * `ipatool auth login` — interactive login. Throws [SpacieError.TwoFactorRequired]
     * when the failure output mentions 2FA keywords AND no auth code was supplied.
     */
    override suspend fun loginAppleID(email: String, password: String, authCode: String?) {
        val ipatool = paths.require("ipatool")

        val args = mutableListOf("auth", "login", "--email", email, "--password", password)
        if (!authCode.isNullOrEmpty()) {
            args += listOf("--auth-code", authCode)
        }

        val result = runner.run(
            executablePath = ipatool,
            arguments = args,
            timeoutSeconds = 30.0
        )

        if (result.exitCode != 0) {
            val raw = (result.stdout.decodeToString() + "\n" + result.stderr.decodeToString()).trim()
            val cleaned = redactSecret(DeviceServiceHelpers.stripANSI(raw).trim(), password)
            val lowered = cleaned.lowercase()

            if (authCode == null && TWO_FA_KEYWORDS.any { lowered.contains(it) }) {
                throw SpacieError.TwoFactorRequired
            }

            throw SpacieError.AuthFailed(if (cleaned.isEmpty()) "Authentication failed" else cleaned)
        }
    }

    /**
     * `ipatool download` — fetches the IPA into [destinationDir] / `<bundleID>.ipa`.
     * Requires an active Apple ID session ([checkAppleIDAuth] must return true).
     */
    suspend fun downloadIPA(
        bundleID: String,
        destinationDir: String,
        onProgress: (Double) -> Unit
    ): String {
        InputValidator.validateBundleID(bundleID)
        val ipatool = paths.require("ipatool")

        if (!checkAppleIDAuth()) {
            throw SpacieError.ExtractionFailed(
                bundleID,
                "Not signed in with Apple ID. Please sign in first."
            )
        }

        val ipaPath = "$destinationDir/$bundleID.ipa"
        onProgress(0.1)

        val result = runner.runWithLineOutput(
            executablePath = ipatool,
            arguments = listOf("download", "-b", bundleID, "-o", ipaPath, "--purchase"),
            timeoutSeconds = 300.0,
            onLine = { onProgress(0.5) }
        )

        if (result.exitCode != 0) {
            val raw = (result.stdout.decodeToString() + "\n" + result.stderr.decodeToString()).trim()
            val out = DeviceServiceHelpers.stripANSI(raw).trim()
            throw SpacieError.ExtractionFailed(
                bundleID,
                if (out.isEmpty()) "ipatool exited with code ${result.exitCode}" else out
            )
        }

        if (!pathExists(ipaPath)) {
            throw SpacieError.ExtractionFailed(bundleID, "IPA was not downloaded to expected path")
        }

        onProgress(1.0)
        return ipaPath
    }

    private fun redactSecret(text: String, secret: String): String {
        if (secret.isEmpty()) return text
        return text.replace(secret, "***")
    }

    private companion object {
        val TWO_FA_KEYWORDS = listOf(
            "two-factor", "2fa", "auth-code", "authentication code",
            "verification code", "two factor", "mfa"
        )
    }
}
