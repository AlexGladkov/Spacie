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
    val stdoutString: String get() = stdout.decodeToString()
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
 * Abstract process runner. Implementations execute external tools asynchronously.
 *
 * Introducing this interface makes [com.spacie.core.api.DeviceServiceApi]
 * implementations testable: production code wires the platform [ProcessRunner]
 * default, tests inject a fake that records arguments and returns scripted
 * [ProcessResult]s without touching the real OS.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessRunnerApi")
interface ProcessRunnerApi {

    suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double? = null,
        stdin: ByteArray? = null,
        env: Map<String, String>? = null
    ): ProcessResult

    suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double? = null,
        stdin: ByteArray? = null,
        env: Map<String, String>? = null,
        onLine: (String) -> Unit
    ): ProcessResult
}

/**
 * Default platform implementation of [ProcessRunnerApi].
 *
 * The `expect` mirrors the [ProcessRunnerApi] surface; both `actual` impls
 * (jvm + macosArm64) implement [ProcessRunnerApi] explicitly so call sites can
 * type their dependency as the interface and accept the production class.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessRunner")
expect class ProcessRunner() : ProcessRunnerApi {

    override suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?
    ): ProcessResult

    override suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?,
        onLine: (String) -> Unit
    ): ProcessResult
}
