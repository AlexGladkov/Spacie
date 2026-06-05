package com.spacie.core.platform

import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class FakeProcessRunnerTest {

    @Test
    fun run_returnsStubbedResult() = runTest {
        val runner = FakeProcessRunner()
        runner.stubResult("/bin/echo", listOf("hi")) {
            ProcessResult(
                stdout = "hi\n".encodeToByteArray(),
                stderr = ByteArray(0),
                exitCode = 0
            )
        }

        val result = runner.run("/bin/echo", listOf("hi"), timeoutSeconds = null)

        assertEquals(0, result.exitCode)
        assertEquals("hi\n", result.stdoutString)
        assertEquals(1, runner.invocations.size)
        assertEquals("/bin/echo", runner.invocations.first().executablePath)
    }

    @Test
    fun runWithLineOutput_emitsStubbedLinesInOrder() = runTest {
        val runner = FakeProcessRunner()
        runner.stub(
            matches = { path, _ -> path == "/usr/local/bin/brew" },
            onLines = listOf("==> Downloading...", "==> Installing...", "==> Done")
        ) {
            ProcessResult(ByteArray(0), ByteArray(0), 0)
        }

        val collected = mutableListOf<String>()
        runner.runWithLineOutput(
            "/usr/local/bin/brew",
            listOf("install", "libimobiledevice"),
            timeoutSeconds = null,
            onLine = { collected.add(it) }
        )

        assertEquals(listOf("==> Downloading...", "==> Installing...", "==> Done"), collected)
        assertTrue(runner.invocations.first().streamedLines)
    }

    @Test
    fun run_unmatchedInvocation_throws() = runTest {
        val runner = FakeProcessRunner()
        assertFailsWith<IllegalStateException> {
            runner.run("/bin/cat", listOf("missing"), timeoutSeconds = null)
        }
    }

    @Test
    fun run_recordsStdinAndEnv() = runTest {
        val runner = FakeProcessRunner()
        runner.stubAnyFor("/bin/sh") {
            ProcessResult(ByteArray(0), ByteArray(0), 0)
        }

        runner.run(
            "/bin/sh",
            emptyList(),
            timeoutSeconds = null,
            stdin = "echo".encodeToByteArray(),
            env = mapOf("KEY" to "value")
        )

        val invocation = runner.invocations.single()
        assertEquals("echo", invocation.stdin!!.decodeToString())
        assertEquals("value", invocation.env!!["KEY"])
    }
}
