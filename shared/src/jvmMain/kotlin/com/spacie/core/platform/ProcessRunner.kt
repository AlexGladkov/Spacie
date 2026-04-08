package com.spacie.core.platform

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.TimeUnit
/** Maximum allowed output size: 100 MiB. */
private const val MAX_OUTPUT_BYTES: Long = 100L * 1024L * 1024L

actual class ProcessRunner actual constructor() {

    actual suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?
    ): ProcessResult = withContext(Dispatchers.IO) {
        val file = File(executablePath)
        if (!file.exists() || !file.canExecute()) {
            throw ProcessError.ExecutableNotFound(executablePath)
        }

        val process = try {
            ProcessBuilder(listOf(executablePath) + arguments)
                .redirectErrorStream(false)
                .start()
        } catch (e: Exception) {
            throw ProcessError.LaunchFailed(e)
        }

        val stdoutBytes: ByteArray
        val stderrBytes: ByteArray

        if (timeoutSeconds != null) {
            // Read streams in parallel before waitFor to avoid pipe-buffer deadlock
            val stdoutFuture = java.util.concurrent.Executors.newSingleThreadExecutor().submit<ByteArray> {
                process.inputStream.readBytes()
            }
            val stderrFuture = java.util.concurrent.Executors.newSingleThreadExecutor().submit<ByteArray> {
                process.errorStream.readBytes()
            }

            val finished = process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
                throw ProcessError.Timeout(File(executablePath).name, timeoutSeconds)
            }

            stdoutBytes = stdoutFuture.get()
            stderrBytes = stderrFuture.get()
        } else {
            // Read both streams fully before waitFor to prevent deadlock
            val stdoutFuture = java.util.concurrent.Executors.newSingleThreadExecutor().submit<ByteArray> {
                process.inputStream.readBytes()
            }
            stderrBytes = process.errorStream.readBytes()
            stdoutBytes = stdoutFuture.get()
            process.waitFor()
        }

        if (stdoutBytes.size.toLong() > MAX_OUTPUT_BYTES || stderrBytes.size.toLong() > MAX_OUTPUT_BYTES) {
            throw ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES)
        }

        ProcessResult(stdoutBytes, stderrBytes, process.exitValue())
    }

    actual suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        onLine: (String) -> Unit
    ): ProcessResult = withContext(Dispatchers.IO) {
        val file = File(executablePath)
        if (!file.exists() || !file.canExecute()) {
            throw ProcessError.ExecutableNotFound(executablePath)
        }

        val process = try {
            ProcessBuilder(listOf(executablePath) + arguments)
                .redirectErrorStream(false)
                .start()
        } catch (e: Exception) {
            throw ProcessError.LaunchFailed(e)
        }

        val stdoutLines = mutableListOf<String>()
        var totalBytes = 0L

        // Collect stderr on a separate thread to prevent deadlock
        val stderrFuture = java.util.concurrent.Executors.newSingleThreadExecutor().submit<ByteArray> {
            process.errorStream.readBytes()
        }

        // Read stdout line-by-line on current (IO) thread
        process.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                val l = line!!
                totalBytes += l.length.toLong()
                if (totalBytes > MAX_OUTPUT_BYTES) {
                    process.destroyForcibly()
                    throw ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES)
                }
                onLine(l)
                stdoutLines.add(l)
            }
        }

        val stderrBytes = stderrFuture.get()

        if (timeoutSeconds != null) {
            val finished = process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
            if (!finished) {
                process.destroyForcibly()
                throw ProcessError.Timeout(File(executablePath).name, timeoutSeconds)
            }
        } else {
            process.waitFor()
        }

        val stdoutBytes = stdoutLines.joinToString("\n").toByteArray(Charsets.UTF_8)
        ProcessResult(stdoutBytes, stderrBytes, process.exitValue())
    }
}
