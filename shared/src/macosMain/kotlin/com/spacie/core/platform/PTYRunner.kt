@file:OptIn(ExperimentalForeignApi::class)

package com.spacie.core.platform

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.IntVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.refTo
import kotlinx.cinterop.toCStringArray
import kotlinx.cinterop.value
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import platform.posix.SIGKILL
import platform.posix.close
import platform.posix.execvp
import platform.posix.kill
import platform.posix.read
import platform.posix.waitpid
import platform.posix.write
import utilpty.kn_forkpty
import kotlin.time.TimeSource

/**
 * Spawns a child process attached to a pseudo-terminal so credentials can be
 * fed via the TTY (stdin) instead of via argv.
 *
 * Used for `ipatool auth login`, which reads its password through
 * `term.ReadPassword` (Go's `golang.org/x/term`) and requires a real TTY
 * (a plain stdin pipe fails with "operation not supported by device").
 *
 * ## Security
 *
 * The password is written to the master fd as raw bytes — never lands in
 * the child's argv. `ps aux` cannot see the secret. Closes the iter0 P0
 * finding documented in `IpaToolClient.kt`.
 *
 * ## Limitations
 *
 * - Blocking POSIX read/write on `Dispatchers.Default`. No cooperative
 *   cancellation inside the syscall. Timeout enforced via wall-clock
 *   monotonic clock.
 * - Output is captured as a single combined stream (PTY collapses
 *   stdout+stderr+echo on the master fd).
 */
internal object PTYRunner {

    data class Result(
        val combinedOutput: String,
        val exitCode: Int,
    )

    /**
     * Spawn [executablePath] with [arguments] in a PTY. When the captured
     * output (case-insensitive) contains [prompt], write [response] + `\n`
     * to the master fd. After the child exits, waitpid reaps it and the
     * function returns the combined output plus exit status.
     */
    suspend fun runWithPrompt(
        executablePath: String,
        arguments: List<String>,
        prompt: String,
        response: String,
        timeoutSeconds: Double = 30.0,
    ): Result = withContext(Dispatchers.Default) {
        memScoped {
            val masterFdVar = alloc<IntVar>()
            val argv = (listOf(executablePath) + arguments).toCStringArray(this)

            val pid = kn_forkpty(masterFdVar.ptr, null)
            check(pid >= 0) { "forkpty failed (errno=${platform.posix.errno})" }
            if (pid == 0) {
                execvp(executablePath, argv)
                platform.posix._exit(127)
            }

            val masterFd = masterFdVar.value
            try {
                runParent(masterFd, pid, prompt, response, timeoutSeconds)
            } finally {
                close(masterFd)
                val status = alloc<IntVar>()
                waitpid(pid, status.ptr, platform.posix.WNOHANG)
            }
        }
    }

    private fun runParent(
        masterFd: Int,
        pid: Int,
        prompt: String,
        response: String,
        timeoutSeconds: Double,
    ): Result = memScoped {
        val output = StringBuilder()
        val buf = allocArray<ByteVar>(4096)
        var responseSent = false
        val timeSource = TimeSource.Monotonic
        val start = timeSource.markNow()
        val timeoutNs = (timeoutSeconds * 1_000_000_000).toLong()

        while (true) {
            val elapsed = start.elapsedNow().inWholeNanoseconds
            if (elapsed > timeoutNs) {
                kill(pid, SIGKILL)
                error("PTYRunner timed out after ${timeoutSeconds}s")
            }
            val n = read(masterFd, buf, 4096uL).toInt()
            if (n <= 0) break
            val chunk = ByteArray(n) { buf[it] }
            val text = chunk.decodeToString()
            output.append(text)

            if (!responseSent && output.toString().lowercase().contains(prompt.lowercase())) {
                val payload = (response + "\n").encodeToByteArray()
                write(masterFd, payload.refTo(0), payload.size.toULong())
                responseSent = true
            }
        }

        // Reap.
        val statusVar = alloc<IntVar>()
        waitpid(pid, statusVar.ptr, 0)
        val raw = statusVar.value
        // POSIX WIFEXITED/WEXITSTATUS via bit manipulation (macOS layout):
        // status is encoded as (exit_status << 8) | term_signal. Extract.
        val exitCode = if ((raw and 0x7F) == 0) (raw shr 8) and 0xFF else -1

        Result(combinedOutput = output.toString(), exitCode = exitCode)
    }
}
