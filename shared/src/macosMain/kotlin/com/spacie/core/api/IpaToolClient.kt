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
 * ## SECURITY — PTY credential injection
 *
 * `ipatool auth login` (v2.3.0+) requires a controlling TTY for password
 * input (it uses `golang.org/x/term` which calls tcgetattr/tcsetattr). When
 * passed via `--password` argv, the secret is briefly visible to any
 * process that can read `/proc/<pid>/argv` (e.g. `ps aux`).
 *
 * To avoid argv exposure, [loginAppleID] spawns `ipatool` through
 * [com.spacie.core.platform.PTYRunner], which uses `forkpty(3)` via a
 * cinterop binding. The password is written to the master fd of the
 * pseudo-terminal in response to ipatool's "enter password:" prompt and
 * never appears in the child's argv.
 *
 * Defence in depth:
 *  - Password redacted from any captured output via [redactSecret].
 *  - Password never logged by us.
 *  - PTY child killed (SIGKILL) on timeout.
 *  - Login is invoked at most once per session; subsequent calls reuse the
 *    cached session token via [checkAppleIDAuth].
 *
 * Users with 2FA can additionally generate an **app-specific password** at
 * <https://appleid.apple.com> to limit blast radius.
 */
internal class IpaToolClient(
    private val runner: ProcessRunnerApi,
    private val paths: ToolPaths,
) : IpaToolClientApi {

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
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            // CancellationException extends Exception in Kotlin — must rethrow
            // BEFORE the generic catch below, otherwise a cancelled transfer
            // would surface to the caller as "Not signed in" (false) instead
            // of propagating cancellation up through downloadIPA.
            throw e
        } catch (_: Exception) {
            false
        }
    }

    /**
     * `ipatool auth login` — interactive login. Throws [SpacieError.TwoFactorRequired]
     * when the failure output mentions 2FA keywords AND no auth code was supplied.
     *
     * Routed through PTYRunner so the password never appears in argv.
     */
    override suspend fun loginAppleID(email: String, password: String, authCode: String?) {
        require(password.isNotEmpty()) { "password must not be empty" }
        val ipatool = paths.require("ipatool")

        // PTY path: feed password through the controlling TTY instead of
        // argv. Closes the iter0 P0 security finding (password no longer
        // visible to `ps aux`). The PTY runner spawns `ipatool` attached to
        // a pseudo-terminal and writes the password when ipatool prompts
        // "enter password:". Auth-code stays in argv because it's
        // short-lived (one-time-use, expires in minutes) and ipatool
        // does not currently prompt for it interactively.
        val pwArgs = mutableListOf("auth", "login", "--email", email)
        if (!authCode.isNullOrEmpty()) {
            pwArgs += listOf("--auth-code", authCode)
        }

        val ptyResult = com.spacie.core.platform.PTYRunner.runWithPrompt(
            executablePath = ipatool,
            arguments = pwArgs,
            prompt = "enter password:",
            response = password,
            timeoutSeconds = 60.0
        )

        if (ptyResult.exitCode != 0) {
            val cleaned = redactSecret(
                DeviceServiceHelpers.stripANSI(ptyResult.combinedOutput).trim(),
                password
            )
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
     *
     * ⚠️ BILLING CONSIDERATION: `--purchase` is currently always passed. For
     * apps the signed-in Apple ID does not yet own, this can silently add the
     * app to the account's library. Apple does not charge for **free** apps,
     * but paid-app metadata could in principle initiate a charge.
     *
     * TODO(billing): add a pre-flight ownership check (`ipatool search` /
     * `ipatool purchase --dry-run`-equivalent) and gate `--purchase` behind
     * explicit user confirmation in the iTransfer UI for any non-free app.
     */
    override suspend fun downloadIPA(
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
            onLine = { line ->
                // Parse "<n>%" tokens from ipatool's stdout (it logs
                // progress lines such as `==> Downloading 42%`). Previously
                // hard-coded to 0.5 — the UI stuck mid-bar for the full
                // download window. parseProgressLine returns a 0.0–1.0
                // double; ignore lines that don't carry a percentage.
                DeviceServiceHelpers.parseProgressLine(line)?.let { onProgress(it) }
            }
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
        // First-pass replace handles the common case. If the password's bytes
        // straddle a non-UTF-8 byte that `decodeToString()` mapped to U+FFFD,
        // the substring search may miss. As a safety net we also check for
        // the password sliced around any replacement chars and any percent /
        // shell-escaped form that ipatool may emit on its own stderr.
        val cleaned = text.replace(secret, "***")
        if (!cleaned.contains(secret)) return cleaned
        // Defensive: byte-by-byte rebuild that skips the secret regardless of
        // surrounding replacement characters. O(n×m) — only on the
        // already-failed fallback path.
        return buildString(cleaned.length) {
            var i = 0
            while (i < cleaned.length) {
                if (cleaned.regionMatches(i, secret, 0, secret.length)) {
                    append("***"); i += secret.length
                } else {
                    append(cleaned[i]); i++
                }
            }
        }
    }

    private companion object {
        val TWO_FA_KEYWORDS = listOf(
            "two-factor", "2fa", "auth-code", "authentication code",
            "verification code", "two factor", "mfa"
        )
    }
}
