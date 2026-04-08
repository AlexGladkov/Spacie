@file:OptIn(ExperimentalForeignApi::class)

package com.spacie.core.platform

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.*
import platform.darwin.*
import platform.posix.memcpy
import kotlin.concurrent.AtomicInt
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/** Maximum allowed output size: 10 MiB. */
private const val MAX_OUTPUT_BYTES: Long = 10L * 1024L * 1024L

/**
 * Convert [NSData] to a Kotlin [ByteArray].
 */
private fun NSData.toByteArray(): ByteArray {
    val len = length.toInt()
    if (len == 0) return ByteArray(0)
    return ByteArray(len).also { ba ->
        val src = bytes ?: return@also
        ba.usePinned { pinned ->
            memcpy(pinned.addressOf(0), src, length)
        }
    }
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessRunner")
actual class ProcessRunner actual constructor() {

    actual suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?
    ): ProcessResult {
        validateExecutable(executablePath)

        return suspendCancellableCoroutine { cont ->
            val resumed = AtomicInt(0)

            val stdoutPipe = NSPipe()
            val stderrPipe = NSPipe()

            val task = NSTask()
            task.setExecutableURL(NSURL.fileURLWithPath(executablePath))
            task.setArguments(arguments)
            task.setStandardOutput(stdoutPipe)
            task.setStandardError(stderrPipe)

            // Cancellation support
            cont.invokeOnCancellation {
                if (task.isRunning()) {
                    task.terminate()
                }
            }

            // Timeout
            if (timeoutSeconds != null && timeoutSeconds > 0.0) {
                val delayNs = (timeoutSeconds * NSEC_PER_SEC.toDouble()).toLong()
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, delayNs),
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND.toLong(), 0u)
                ) {
                    if (task.isRunning()) {
                        task.terminate()
                    }
                    if (resumed.compareAndSet(0, 1)) {
                        cont.resumeWithException(
                            ProcessError.Timeout(executablePath, timeoutSeconds)
                        )
                    }
                }
            }

            val onTermination: (NSTask?) -> Unit = { _ ->
                if (resumed.compareAndSet(0, 1)) {
                    val stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    val stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    val tooLarge = stdoutData.length.toLong() > MAX_OUTPUT_BYTES ||
                        stderrData.length.toLong() > MAX_OUTPUT_BYTES

                    if (tooLarge) {
                        cont.resumeWithException(ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES))
                    } else {
                        cont.resume(
                            ProcessResult(
                                stdout = stdoutData.toByteArray(),
                                stderr = stderrData.toByteArray(),
                                exitCode = task.terminationStatus()
                            )
                        )
                    }
                }
            }
            task.terminationHandler = onTermination

            try {
                task.launch()
            } catch (e: Exception) {
                if (resumed.compareAndSet(0, 1)) {
                    cont.resumeWithException(ProcessError.LaunchFailed(e))
                }
            }
        }
    }

    actual suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        onLine: (String) -> Unit
    ): ProcessResult {
        validateExecutable(executablePath)

        return suspendCancellableCoroutine { cont ->
            val resumed = AtomicInt(0)
            val stdoutChunks = mutableListOf<ByteArray>()
            var totalStdoutBytes = 0L

            val stdoutPipe = NSPipe()
            val stderrPipe = NSPipe()

            val task = NSTask()
            task.setExecutableURL(NSURL.fileURLWithPath(executablePath))
            task.setArguments(arguments)
            task.setStandardOutput(stdoutPipe)
            task.setStandardError(stderrPipe)

            cont.invokeOnCancellation {
                if (task.isRunning()) {
                    task.terminate()
                }
            }

            // Timeout
            if (timeoutSeconds != null && timeoutSeconds > 0.0) {
                val delayNs = (timeoutSeconds * NSEC_PER_SEC.toDouble()).toLong()
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, delayNs),
                    dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND.toLong(), 0u)
                ) {
                    if (task.isRunning()) {
                        task.terminate()
                    }
                    if (resumed.compareAndSet(0, 1)) {
                        cont.resumeWithException(
                            ProcessError.Timeout(executablePath, timeoutSeconds)
                        )
                    }
                }
            }

            // Incremental line reading from stdout
            var lineBuffer = StringBuilder()
            val stdoutHandle = stdoutPipe.fileHandleForReading

            val onRead: (NSFileHandle?) -> Unit = onRead@{ handle ->
                if (handle == null) return@onRead
                val chunk = handle.availableData()
                if (chunk.length.toInt() > 0) {
                    totalStdoutBytes += chunk.length.toLong()
                    if (totalStdoutBytes > MAX_OUTPUT_BYTES) {
                        stdoutHandle.readabilityHandler = null
                        if (task.isRunning()) task.terminate()
                        if (resumed.compareAndSet(0, 1)) {
                            cont.resumeWithException(ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES))
                        }
                        return@onRead
                    }

                    val bytes = chunk.toByteArray()
                    stdoutChunks.add(bytes)

                    val text = bytes.decodeToString()
                    for (char in text) {
                        if (char == '\n') {
                            onLine(lineBuffer.toString())
                            lineBuffer = StringBuilder()
                        } else {
                            lineBuffer.append(char)
                        }
                    }
                } else {
                    // EOF -- flush remaining buffer
                    if (lineBuffer.isNotEmpty()) {
                        onLine(lineBuffer.toString())
                        lineBuffer = StringBuilder()
                    }
                }
            }
            stdoutHandle.readabilityHandler = onRead

            val onTermination: (NSTask?) -> Unit = { _ ->
                // Disable readability handler
                stdoutHandle.readabilityHandler = null

                if (resumed.compareAndSet(0, 1)) {
                    // Flush any remaining line buffer
                    if (lineBuffer.isNotEmpty()) {
                        onLine(lineBuffer.toString())
                    }

                    val stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    val fullStdout = concatenateChunks(stdoutChunks)

                    cont.resume(
                        ProcessResult(
                            stdout = fullStdout,
                            stderr = stderrData.toByteArray(),
                            exitCode = task.terminationStatus()
                        )
                    )
                }
            }
            task.terminationHandler = onTermination

            try {
                task.launch()
            } catch (e: Exception) {
                stdoutHandle.readabilityHandler = null
                if (resumed.compareAndSet(0, 1)) {
                    cont.resumeWithException(ProcessError.LaunchFailed(e))
                }
            }
        }
    }

    private fun validateExecutable(path: String) {
        if (!NSFileManager.defaultManager.isExecutableFileAtPath(path)) {
            throw ProcessError.ExecutableNotFound(path)
        }
    }

    private fun concatenateChunks(chunks: List<ByteArray>): ByteArray {
        val totalSize = chunks.sumOf { it.size }
        val result = ByteArray(totalSize)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(result, offset)
            offset += chunk.size
        }
        return result
    }
}
