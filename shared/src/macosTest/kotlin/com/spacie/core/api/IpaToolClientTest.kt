package com.spacie.core.api

import com.spacie.core.api.internal.ToolPaths
import com.spacie.core.error.SpacieError
import com.spacie.core.platform.FakeProcessRunner
import com.spacie.core.platform.HomebrewResolver
import com.spacie.core.platform.ProcessResult
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class IpaToolClientTest {

    // Use a real HomebrewResolver but bypass its actual file probe by relying on
    // the ipatool path it would return on this machine, OR stub via ToolPaths
    // by providing a resolver that returns a Ready status. Simpler: build a
    // fake ToolPaths via the resolver after we have known paths.
    //
    // Pragmatic approach: instantiate with a real resolver that may not resolve
    // and use ToolPaths.optional() — for client tests we'll provide the runner
    // stubs and call helper methods that build their own ToolPaths.
    private fun setup(): Pair<FakeProcessRunner, IpaToolClient> {
        val runner = FakeProcessRunner()
        // The resolver here is unused because we stub `ipatool` invocations
        // by full path — IpaToolClient.checkAppleIDAuth returns false if path
        // is null, so we need to inject a path. Use a StubToolPaths via reflection
        // would be over-engineered; create a subclass override via a thin
        // wrapper for tests.
        val client = IpaToolClient(runner, StubToolPaths(mapOf("ipatool" to "/opt/homebrew/bin/ipatool")))
        return runner to client
    }

    @Test
    fun checkAppleIDAuth_returnsTrue_whenAuthInfoExits0() = runTest {
        val (runner, client) = setup()
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "info")
        ) { ProcessResult(ByteArray(0), ByteArray(0), exitCode = 0) }

        assertTrue(client.checkAppleIDAuth())
    }

    @Test
    fun checkAppleIDAuth_returnsFalse_whenExitNonZero() = runTest {
        val (runner, client) = setup()
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "info")
        ) { ProcessResult(ByteArray(0), "no session".encodeToByteArray(), exitCode = 1) }

        assertFalse(client.checkAppleIDAuth())
    }

    @Test
    fun checkAppleIDAuth_returnsFalse_whenIpatoolPathMissing() = runTest {
        val runner = FakeProcessRunner()
        val client = IpaToolClient(runner, StubToolPaths(emptyMap()))

        assertFalse(client.checkAppleIDAuth())
        assertEquals(0, runner.invocations.size, "should not invoke runner without ipatool path")
    }

    @Test
    fun loginAppleID_success_doesNotThrow() = runTest {
        val (runner, client) = setup()
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "login", "--email", "x@y.z", "--password", "secret")
        ) { ProcessResult(ByteArray(0), ByteArray(0), exitCode = 0) }

        client.loginAppleID("x@y.z", "secret", authCode = null)

        assertEquals(1, runner.invocations.size)
    }

    @Test
    fun loginAppleID_twoFactorRequired_thrownWhenStderrMentionsKeyword() = runTest {
        val (runner, client) = setup()
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "login", "--email", "x@y.z", "--password", "secret")
        ) {
            ProcessResult(
                stdout = ByteArray(0),
                stderr = "two-factor authentication code required".encodeToByteArray(),
                exitCode = 1
            )
        }

        assertFailsWith<SpacieError.TwoFactorRequired> {
            client.loginAppleID("x@y.z", "secret", authCode = null)
        }
    }

    @Test
    fun loginAppleID_authFailed_redactsPasswordInErrorMessage() = runTest {
        val (runner, client) = setup()
        val password = "p@ssword-LEAK"
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "login", "--email", "x@y.z", "--password", password)
        ) {
            ProcessResult(
                stdout = ByteArray(0),
                // ipatool sometimes echoes the failed command back in stderr.
                stderr = "tried $password — denied".encodeToByteArray(),
                exitCode = 1
            )
        }

        val err = assertFailsWith<SpacieError.AuthFailed> {
            client.loginAppleID("x@y.z", password, authCode = null)
        }

        assertFalse(err.message.contains(password), "password leaked into AuthFailed message")
        assertTrue(err.message.contains("***"), "redaction marker absent")
    }

    @Test
    fun loginAppleID_authCodePresent_doesNotTriggerTwoFactorRequired() = runTest {
        val (runner, client) = setup()
        runner.stubResult(
            "/opt/homebrew/bin/ipatool",
            listOf("auth", "login", "--email", "x@y.z", "--password", "secret", "--auth-code", "123456")
        ) {
            ProcessResult(
                stdout = ByteArray(0),
                // Stderr mentions 2FA but we already supplied the code → should be AuthFailed.
                stderr = "two-factor auth-code wrong".encodeToByteArray(),
                exitCode = 1
            )
        }

        assertFailsWith<SpacieError.AuthFailed> {
            client.loginAppleID("x@y.z", "secret", authCode = "123456")
        }
    }
}

