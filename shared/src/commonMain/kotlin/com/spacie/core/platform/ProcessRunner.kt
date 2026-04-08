package com.spacie.core.platform

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Result of a process execution.
 *
 * @property stdout raw standard output bytes
 * @property stderr raw standard error bytes
 * @property exitCode process exit code (0 = success)
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessResult")
data class ProcessResult(
    val stdout: ByteArray,
    val stderr: ByteArray,
    val exitCode: Int
) {
    /** Convenience: stdout decoded as UTF-8. */
    val stdoutString: String get() = stdout.decodeToString()

    /** Convenience: stderr decoded as UTF-8. */
    val stderrString: String get() = stderr.decodeToString()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ProcessResult) return false
        return exitCode == other.exitCode &&
            stdout.contentEquals(other.stdout) &&
            stderr.contentEquals(other.stderr)
    }

    override fun hashCode(): Int {
        var result = stdout.contentHashCode()
        result = 31 * result + stderr.contentHashCode()
        result = 31 * result + exitCode
        return result
    }
}

/**
 * Sealed hierarchy of process execution errors.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessError")
sealed class ProcessError(message: String) : Exception(message) {
    class ExecutableNotFound(val path: String) :
        ProcessError("Executable not found: $path")

    class LaunchFailed(override val cause: Throwable?) :
        ProcessError("Launch failed: ${cause?.message ?: "unknown"}")

    class Timeout(val tool: String, val seconds: Double) :
        ProcessError("Timeout after ${seconds}s: $tool")

    class OutputTooLarge(val limitBytes: Long) :
        ProcessError("Output exceeds limit of $limitBytes bytes")

    class Cancelled(override val cause: Throwable?) :
        ProcessError("Process cancelled")
}

/**
 * Platform process runner. Executes external tools asynchronously.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessRunner")
expect class ProcessRunner() {

    /**
     * Run an external process and collect its output.
     *
     * @param executablePath absolute path to the executable
     * @param arguments command-line arguments
     * @param timeoutSeconds optional timeout; null = no timeout
     * @return [ProcessResult] with stdout, stderr, and exit code
     * @throws ProcessError on failure
     */
    suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?
    ): ProcessResult

    /**
     * Run an external process, streaming stdout line-by-line.
     *
     * @param executablePath absolute path to the executable
     * @param arguments command-line arguments
     * @param timeoutSeconds optional timeout; null = no timeout
     * @param onLine callback invoked for each line of stdout
     * @return [ProcessResult] with full stdout, stderr, and exit code
     * @throws ProcessError on failure
     */
    suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        onLine: (String) -> Unit
    ): ProcessResult
}
