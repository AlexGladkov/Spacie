package com.spacie.core.platform

import kotlinx.atomicfu.locks.SynchronizedObject
import kotlinx.atomicfu.locks.synchronized

/**
 * Test double for [ProcessRunnerApi] that records every invocation and returns
 * scripted results.
 *
 * ## Usage
 *
 * ```kotlin
 * val runner = FakeProcessRunner().apply {
 *     stubResult("/opt/homebrew/bin/idevice_id", listOf("-l")) {
 *         ProcessResult(stdout = "udid-1\n".encodeToByteArray(), stderr = ByteArray(0), exitCode = 0)
 *     }
 * }
 * val service = DeviceServiceImpl(runner = runner)
 * val devices = service.listDevices()
 * assertEquals(1, devices.size)
 * assertEquals(1, runner.invocations.size)
 * ```
 *
 * Unmatched invocations either return [defaultResult] (when configured) or
 * throw [IllegalStateException] so missing stubs surface fast in tests.
 *
 * Thread-safe so concurrent coroutines can drive the runner.
 */
class FakeProcessRunner : ProcessRunnerApi {

    /** A single recorded process invocation. */
    data class Invocation(
        val executablePath: String,
        val arguments: List<String>,
        val stdin: ByteArray?,
        val env: Map<String, String>?,
        val streamedLines: Boolean
    )

    private val lock = SynchronizedObject()
    private val _invocations = mutableListOf<Invocation>()
    private val stubs = mutableListOf<Stub>()

    /** Default result returned when no stub matches. */
    var defaultResult: (() -> ProcessResult)? = null

    /** Default lines emitted to onLine when no stub matches and [defaultResult] is set. */
    var defaultLines: List<String> = emptyList()

    /** All invocations in order. Safe to read from any thread. */
    val invocations: List<Invocation>
        get() = synchronized(lock) { _invocations.toList() }

    /**
     * Register a scripted response for any future call whose arguments satisfy [matches].
     *
     * @param matches predicate over `(executablePath, arguments)`
     * @param onLines optional list of lines that [runWithLineOutput] will deliver via `onLine`
     * @param result lambda producing the result; can throw to simulate errors
     */
    fun stub(
        matches: (executablePath: String, arguments: List<String>) -> Boolean,
        onLines: List<String> = emptyList(),
        result: () -> ProcessResult
    ) {
        synchronized(lock) { stubs.add(Stub(matches, onLines, result)) }
    }

    /** Convenience helper: stub by exact executable + arguments. */
    fun stubResult(
        executablePath: String,
        arguments: List<String>,
        onLines: List<String> = emptyList(),
        result: () -> ProcessResult
    ) {
        stub(
            matches = { path, args -> path == executablePath && args == arguments },
            onLines = onLines,
            result = result
        )
    }

    /** Convenience helper: stub by executable path only. */
    fun stubAnyFor(
        executablePath: String,
        onLines: List<String> = emptyList(),
        result: () -> ProcessResult
    ) {
        stub(
            matches = { path, _ -> path == executablePath },
            onLines = onLines,
            result = result
        )
    }

    /** Reset all recorded invocations (stubs are kept). */
    fun resetInvocations() {
        synchronized(lock) { _invocations.clear() }
    }

    /** Reset both stubs and recorded invocations. */
    fun reset() {
        synchronized(lock) {
            _invocations.clear()
            stubs.clear()
            defaultResult = null
            defaultLines = emptyList()
        }
    }

    override suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?
    ): ProcessResult {
        record(
            Invocation(executablePath, arguments, stdin, env, streamedLines = false)
        )
        return findResult(executablePath, arguments)
    }

    override suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?,
        onLine: (String) -> Unit
    ): ProcessResult {
        record(
            Invocation(executablePath, arguments, stdin, env, streamedLines = true)
        )
        val (lines, result) = findStreamingResult(executablePath, arguments)
        for (line in lines) onLine(line)
        return result
    }

    private fun record(invocation: Invocation) {
        synchronized(lock) { _invocations.add(invocation) }
    }

    private fun findResult(executablePath: String, arguments: List<String>): ProcessResult {
        val stub = synchronized(lock) { stubs.firstOrNull { it.matches(executablePath, arguments) } }
        return stub?.result?.invoke()
            ?: defaultResult?.invoke()
            ?: error("FakeProcessRunner: no stub for $executablePath ${arguments.joinToString(" ")}")
    }

    private fun findStreamingResult(
        executablePath: String,
        arguments: List<String>
    ): Pair<List<String>, ProcessResult> {
        val stub = synchronized(lock) { stubs.firstOrNull { it.matches(executablePath, arguments) } }
        return if (stub != null) {
            stub.onLines to stub.result.invoke()
        } else {
            defaultLines to (defaultResult?.invoke()
                ?: error("FakeProcessRunner: no stub for $executablePath ${arguments.joinToString(" ")}"))
        }
    }

    private class Stub(
        val matches: (String, List<String>) -> Boolean,
        val onLines: List<String>,
        val result: () -> ProcessResult
    )
}
