package com.spacie.core.platform

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import java.io.File
import java.io.OutputStream
import java.util.concurrent.TimeUnit

/** Maximum allowed output size: 100 MiB. */
private const val MAX_OUTPUT_BYTES: Long = 100L * 1024L * 1024L

actual class ProcessRunner actual constructor() {

    actual suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?
    ): ProcessResult = withContext(Dispatchers.IO) {
        val file = File(executablePath)
        if (!file.exists() || !file.canExecute()) {
            throw ProcessError.ExecutableNotFound(executablePath)
        }

        val process = try {
            ProcessBuilder(listOf(executablePath) + arguments)
                .redirectErrorStream(false)
                .also { pb ->
                    env?.let { pb.environment().putAll(it) }
                }
                .start()
        } catch (e: Exception) {
            throw ProcessError.LaunchFailed(e)
        }

        try {
            if (stdin != null) {
                writeStdin(process.outputStream, stdin)
            } else {
                runCatching { process.outputStream.close() }
            }

            coroutineScope {
                val stdoutDeferred = async(Dispatchers.IO) {
                    runInterruptible { process.inputStream.readBytes() }
                }
                val stderrDeferred = async(Dispatchers.IO) {
                    runInterruptible { process.errorStream.readBytes() }
                }

                val finished = if (timeoutSeconds != null) {
                    runInterruptible {
                        process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
                    }
                } else {
                    runInterruptible { process.waitFor() }
                    true
                }

                if (!finished) {
                    throw ProcessError.Timeout(File(executablePath).name, timeoutSeconds!!)
                }

                val stdoutBytes = stdoutDeferred.await()
                val stderrBytes = stderrDeferred.await()

                if (stdoutBytes.size.toLong() > MAX_OUTPUT_BYTES ||
                    stderrBytes.size.toLong() > MAX_OUTPUT_BYTES
                ) {
                    throw ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES)
                }

                ProcessResult(stdoutBytes, stderrBytes, process.exitValue())
            }
        } catch (e: CancellationException) {
            destroyProcess(process)
            throw e
        } catch (e: ProcessError) {
            destroyProcess(process)
            throw e
        } catch (e: Exception) {
            destroyProcess(process)
            throw ProcessError.LaunchFailed(e)
        } finally {
            if (process.isAlive) {
                destroyProcess(process)
            }
        }
    }

    actual suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?,
        onLine: (String) -> Unit
    ): ProcessResult = withContext(Dispatchers.IO) {
        val file = File(executablePath)
        if (!file.exists() || !file.canExecute()) {
            throw ProcessError.ExecutableNotFound(executablePath)
        }

        val process = try {
            ProcessBuilder(listOf(executablePath) + arguments)
                .redirectErrorStream(false)
                .also { pb ->
                    env?.let { pb.environment().putAll(it) }
                }
                .start()
        } catch (e: Exception) {
            throw ProcessError.LaunchFailed(e)
        }

        try {
            if (stdin != null) {
                writeStdin(process.outputStream, stdin)
            } else {
                runCatching { process.outputStream.close() }
            }

            coroutineScope {
                val stderrDeferred = async(Dispatchers.IO) {
                    runInterruptible { process.errorStream.readBytes() }
                }

                val stdoutLines = mutableListOf<String>()
                var totalBytes = 0L

                runInterruptible {
                    process.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                        var line: String?
                        while (reader.readLine().also { line = it } != null) {
                            val l = line!!
                            totalBytes += l.length.toLong()
                            if (totalBytes > MAX_OUTPUT_BYTES) {
                                throw ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES)
                            }
                            onLine(l)
                            stdoutLines.add(l)
                        }
                    }
                }

                val stderrBytes = stderrDeferred.await()

                val finished = if (timeoutSeconds != null) {
                    runInterruptible {
                        process.waitFor(timeoutSeconds.toLong(), TimeUnit.SECONDS)
                    }
                } else {
                    runInterruptible { process.waitFor() }
                    true
                }

                if (!finished) {
                    throw ProcessError.Timeout(File(executablePath).name, timeoutSeconds!!)
                }

                val stdoutBytes = stdoutLines.joinToString("\n").toByteArray(Charsets.UTF_8)
                ProcessResult(stdoutBytes, stderrBytes, process.exitValue())
            }
        } catch (e: CancellationException) {
            destroyProcess(process)
            throw e
        } catch (e: ProcessError) {
            destroyProcess(process)
            throw e
        } catch (e: Exception) {
            destroyProcess(process)
            throw ProcessError.LaunchFailed(e)
        } finally {
            if (process.isAlive) {
                destroyProcess(process)
            }
        }
    }

    private fun writeStdin(stream: OutputStream, data: ByteArray) {
        try {
            stream.use { it.write(data) }
        } catch (_: Exception) {
        }
    }

    private fun destroyProcess(process: Process) {
        runCatching { process.destroy() }
        if (process.isAlive) {
            runCatching {
                if (!process.waitFor(500, TimeUnit.MILLISECONDS)) {
                    process.destroyForcibly()
                }
            }
        }
    }
}
