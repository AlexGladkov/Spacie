@file:OptIn(ExperimentalForeignApi::class)

package com.spacie.core.platform

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.*
import platform.darwin.*
import platform.posix.memcpy
import platform.posix.read
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

/**
 * Reads remaining bytes from an [NSFileHandle] safely via the POSIX `read()`
 * syscall (no `NSException` on closed pipe / EBADF). Caps at [maxBytes].
 *
 * `NSFileHandle.readDataToEndOfFile()` throws an Objective-C `NSException` when
 * the underlying file descriptor has been closed (e.g. by termination/cancellation
 * race). NSException does not bridge to Kotlin `Throwable`, so we cannot catch it
 * — the process crashes. Reading via `read(2)` on the raw fd surfaces errors as
 * a negative return code without raising.
 */
private fun NSFileHandle.readToEndSafely(maxBytes: Long = MAX_OUTPUT_BYTES): ByteArray {
    val fd = fileDescriptor
    if (fd < 0) return ByteArray(0)
    val chunks = mutableListOf<ByteArray>()
    var total = 0L
    val bufSize = 8192
    memScoped {
        val buf = allocArray<ByteVar>(bufSize)
        while (total < maxBytes) {
            val n = read(fd, buf, bufSize.toULong()).toInt()
            if (n <= 0) break // EOF or error (EBADF, EAGAIN, etc.) — no exception
            val chunk = ByteArray(n)
            for (i in 0 until n) chunk[i] = buf[i]
            chunks.add(chunk)
            total += n
        }
    }
    if (chunks.isEmpty()) return ByteArray(0)
    val result = ByteArray(chunks.sumOf { it.size })
    var off = 0
    for (c in chunks) {
        c.copyInto(result, off); off += c.size
    }
    return result
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaProcessRunner")
actual class ProcessRunner actual constructor() : ProcessRunnerApi {

    actual override suspend fun run(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?
    ): ProcessResult {
        validateExecutable(executablePath)

        return suspendCancellableCoroutine { cont ->
            val resumed = AtomicInt(0)

            val stdoutPipe = NSPipe()
            val stderrPipe = NSPipe()
            val stdinPipe = if (stdin != null) NSPipe() else null

            val task = NSTask()
            task.setExecutableURL(NSURL.fileURLWithPath(executablePath))
            task.setArguments(arguments)
            task.setStandardOutput(stdoutPipe)
            task.setStandardError(stderrPipe)
            stdinPipe?.let { task.setStandardInput(it) }
            if (env != null) {
                val current = NSProcessInfo.processInfo.environment as Map<Any?, *>
                val merged = HashMap<Any?, Any?>(current)
                for ((k, v) in env) merged[k] = v
                task.setEnvironment(merged)
            }

            // Cancellation support. Pre-launch cancellation (the narrow
            // window between invokeOnCancellation registration and
            // task.launch()) is handled by checking `cont.isActive` again at
            // launch time below — terminating an unstarted NSTask is a
            // no-op, so the runtime guard is enough.
            cont.invokeOnCancellation {
                if (task.isRunning()) {
                    task.terminate()
                }
            }

            // Timeout via cancellable dispatch_source_timer instead of
            // dispatch_after. dispatch_after blocks cannot be cancelled —
            // captured `cont`, `task`, and both NSPipes stay live until
            // the timer naturally fires (up to 300s on downloadIPA). A
            // dispatch_source can be cancelled from onTermination, which
            // releases the captures immediately on natural exit.
            val timeoutSource: dispatch_source_t? = if (timeoutSeconds != null && timeoutSeconds > 0.0) {
                val queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND.toLong(), 0u)
                val source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0u, 0u, queue)
                if (source != null) {
                    val delayNs = (timeoutSeconds * NSEC_PER_SEC.toDouble()).toLong()
                    dispatch_source_set_timer(
                        source,
                        dispatch_time(DISPATCH_TIME_NOW, delayNs),
                        DISPATCH_TIME_FOREVER,
                        0u
                    )
                    dispatch_source_set_event_handler(source) {
                        if (resumed.value != 0) return@dispatch_source_set_event_handler
                        if (task.isRunning()) task.terminate()
                        if (resumed.compareAndSet(0, 1)) {
                            cont.resumeWithException(
                                ProcessError.Timeout(executablePath, timeoutSeconds)
                            )
                        }
                    }
                    dispatch_resume(source)
                }
                source
            } else null

            val onTermination: (NSTask?) -> Unit = { _ ->
                // Cancel the timer immediately on natural exit so its
                // captured strong refs to cont/task/pipes are released
                // now instead of when the (potentially 300s) deadline
                // fires. dispatch_source_cancel is idempotent + safe to
                // call from any queue.
                timeoutSource?.let { dispatch_source_cancel(it) }
                if (resumed.compareAndSet(0, 1)) {
                    // Safe POSIX read: never throws NSException on closed pipe.
                    val stdoutBytes = stdoutPipe.fileHandleForReading.readToEndSafely(MAX_OUTPUT_BYTES + 1)
                    val stderrBytes = stderrPipe.fileHandleForReading.readToEndSafely(MAX_OUTPUT_BYTES + 1)

                    val tooLarge = stdoutBytes.size.toLong() > MAX_OUTPUT_BYTES ||
                        stderrBytes.size.toLong() > MAX_OUTPUT_BYTES

                    if (tooLarge) {
                        cont.resumeWithException(ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES))
                    } else {
                        cont.resume(
                            ProcessResult(
                                stdout = stdoutBytes,
                                stderr = stderrBytes,
                                exitCode = task.terminationStatus()
                            )
                        )
                    }
                }
            }
            task.terminationHandler = onTermination

            try {
                // Pre-launch cancellation guard: if the coroutine was
                // cancelled in the window between `invokeOnCancellation`
                // registration and here, do NOT spawn the subprocess at all
                // — terminating it post-launch would leak a transient
                // subprocess plus its open fds until natural exit.
                if (!cont.isActive) {
                    if (resumed.compareAndSet(0, 1)) {
                        cont.resumeWithException(
                            kotlin.coroutines.cancellation.CancellationException(
                                "Cancelled before launch"
                            )
                        )
                    }
                    return@suspendCancellableCoroutine
                }
                task.launch()
                stdinPipe?.let { pipe ->
                    writeStdin(pipe, stdin!!)
                }
            } catch (e: Exception) {
                if (resumed.compareAndSet(0, 1)) {
                    cont.resumeWithException(ProcessError.LaunchFailed(e))
                }
            }
        }
    }

    actual override suspend fun runWithLineOutput(
        executablePath: String,
        arguments: List<String>,
        timeoutSeconds: Double?,
        stdin: ByteArray?,
        env: Map<String, String>?,
        onLine: (String) -> Unit
    ): ProcessResult {
        validateExecutable(executablePath)

        return suspendCancellableCoroutine { cont ->
            val resumed = AtomicInt(0)
            // Semaphore serializes access to shared mutable state (lineBuffer, stdoutChunks,
            // totalStdoutBytes[0]) between onRead (NSFileHandle readability queue) and
            // onTermination (NSTask termination queue), which run on independent GCD threads.
            // dispatch_semaphore_create returns nullable in K/N (returns null on
            // OOM). Passing a null semaphore to dispatch_semaphore_wait below
            // would crash native with EXC_BAD_ACCESS (uncatchable from Kotlin)
            // for any long-running CLI invocation under memory pressure.
            val ioLock = checkNotNull(dispatch_semaphore_create(1)) {
                "dispatch_semaphore_create failed (OOM)"
            }
            val stdoutChunks = mutableListOf<ByteArray>()
            val totalStdoutBytes = longArrayOf(0L)
            val lineBuffer = StringBuilder()

            val stdoutPipe = NSPipe()
            val stderrPipe = NSPipe()
            val stdinPipe = if (stdin != null) NSPipe() else null

            val task = NSTask()
            task.setExecutableURL(NSURL.fileURLWithPath(executablePath))
            task.setArguments(arguments)
            task.setStandardOutput(stdoutPipe)
            task.setStandardError(stderrPipe)
            stdinPipe?.let { task.setStandardInput(it) }
            if (env != null) {
                val current = NSProcessInfo.processInfo.environment as Map<Any?, *>
                val merged = HashMap<Any?, Any?>(current)
                for ((k, v) in env) merged[k] = v
                task.setEnvironment(merged)
            }

            val stdoutHandle = stdoutPipe.fileHandleForReading

            cont.invokeOnCancellation {
                // Detach handler BEFORE terminate to prevent further onRead callbacks
                // holding strong references to cont/lineBuffer/stdoutChunks.
                stdoutHandle.readabilityHandler = null
                if (task.isRunning()) {
                    task.terminate()
                }
            }

            // Cancellable timeout — same dispatch_source_timer pattern as run().
            val timeoutSource: dispatch_source_t? = if (timeoutSeconds != null && timeoutSeconds > 0.0) {
                val queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND.toLong(), 0u)
                val source = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0u, 0u, queue)
                if (source != null) {
                    val delayNs = (timeoutSeconds * NSEC_PER_SEC.toDouble()).toLong()
                    dispatch_source_set_timer(
                        source,
                        dispatch_time(DISPATCH_TIME_NOW, delayNs),
                        DISPATCH_TIME_FOREVER,
                        0u
                    )
                    dispatch_source_set_event_handler(source) {
                        if (resumed.value != 0) return@dispatch_source_set_event_handler
                        stdoutHandle.readabilityHandler = null
                        if (task.isRunning()) task.terminate()
                        if (resumed.compareAndSet(0, 1)) {
                            cont.resumeWithException(
                                ProcessError.Timeout(executablePath, timeoutSeconds)
                            )
                        }
                    }
                    dispatch_resume(source)
                }
                source
            } else null

            val onRead: (NSFileHandle?) -> Unit = onRead@{ handle ->
                if (handle == null) return@onRead
                val chunk = handle.availableData()
                val chunkLen = chunk.length.toInt()
                if (chunkLen == 0) {
                    // EOF -- flush remaining buffer. Collect inside the lock,
                    // emit outside — onLine is user code and could block on
                    // a resource the termination handler also needs.
                    val flushed: String? = withSemaphoreLock(ioLock) {
                        if (lineBuffer.isNotEmpty()) {
                            val s = lineBuffer.toString()
                            lineBuffer.setLength(0)
                            s
                        } else null
                    }
                    if (flushed != null) onLine(flushed)
                    return@onRead
                }
                val bytes = chunk.toByteArray()
                // Single critical section for shared-state mutation. Emit the
                // collected lines AFTER releasing the lock so user-supplied
                // onLine cannot deadlock against onTermination.
                val pendingLines = mutableListOf<String>()
                val didClaimResume = withSemaphoreLock(ioLock) {
                    totalStdoutBytes[0] += chunkLen.toLong()
                    val isOver = totalStdoutBytes[0] > MAX_OUTPUT_BYTES
                    if (!isOver) {
                        stdoutChunks.add(bytes)
                        val text = bytes.decodeToString()
                        for (char in text) {
                            if (char == '\n') {
                                pendingLines.add(lineBuffer.toString())
                                lineBuffer.setLength(0)
                            } else {
                                lineBuffer.append(char)
                            }
                        }
                        return@withSemaphoreLock false
                    }
                    // Over limit: claim the resume slot inside the lock so the
                    // termination handler will skip its read-and-resume path.
                    resumed.compareAndSet(0, 1)
                }
                // Emit collected lines outside the lock.
                for (line in pendingLines) onLine(line)
                if (didClaimResume) {
                    stdoutHandle.readabilityHandler = null
                    if (task.isRunning()) task.terminate()
                    cont.resumeWithException(ProcessError.OutputTooLarge(MAX_OUTPUT_BYTES))
                }
            }
            stdoutHandle.readabilityHandler = onRead

            val onTermination: (NSTask?) -> Unit = { _ ->
                // Cancel the timer to release its captures (cont, task,
                // pipes, lineBuffer, stdoutChunks, ioLock) immediately
                // instead of holding them until the deadline fires.
                timeoutSource?.let { dispatch_source_cancel(it) }
                // Detach handler first to stop new onRead callbacks; ioLock then ensures
                // any in-flight onRead completes before we read shared state.
                stdoutHandle.readabilityHandler = null

                if (resumed.compareAndSet(0, 1)) {
                    var finalLine: String? = null
                    val fullStdout = withSemaphoreLock(ioLock) {
                        if (lineBuffer.isNotEmpty()) {
                            finalLine = lineBuffer.toString()
                            lineBuffer.setLength(0)
                        }
                        concatenateChunks(stdoutChunks)
                    }
                    // Guard against user-callback exceptions: if onLine throws,
                    // we must still reach cont.resume below, otherwise the
                    // coroutine is suspended forever.
                    if (finalLine != null) {
                        // Catch Exception (not Throwable) so fatal native
                        // errors (OOM, stack overflow) still propagate up.
                        try { onLine(finalLine!!) } catch (_: Exception) { /* swallow */ }
                    }

                    val stderrBytes = stderrPipe.fileHandleForReading.readToEndSafely(MAX_OUTPUT_BYTES + 1)

                    cont.resume(
                        ProcessResult(
                            stdout = fullStdout,
                            stderr = stderrBytes,
                            exitCode = task.terminationStatus()
                        )
                    )
                }
            }
            task.terminationHandler = onTermination

            try {
                // Pre-launch cancellation guard — see run() for rationale.
                if (!cont.isActive) {
                    stdoutHandle.readabilityHandler = null
                    if (resumed.compareAndSet(0, 1)) {
                        cont.resumeWithException(
                            kotlin.coroutines.cancellation.CancellationException(
                                "Cancelled before launch"
                            )
                        )
                    }
                    return@suspendCancellableCoroutine
                }
                task.launch()
                stdinPipe?.let { pipe ->
                    writeStdin(pipe, stdin!!)
                }
            } catch (e: Exception) {
                stdoutHandle.readabilityHandler = null
                if (resumed.compareAndSet(0, 1)) {
                    cont.resumeWithException(ProcessError.LaunchFailed(e))
                }
            }
        }
    }

    private inline fun <T> withSemaphoreLock(sem: dispatch_semaphore_t?, block: () -> T): T {
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER)
        return try {
            block()
        } finally {
            dispatch_semaphore_signal(sem)
        }
    }

    private fun validateExecutable(path: String) {
        if (!NSFileManager.defaultManager.isExecutableFileAtPath(path)) {
            throw ProcessError.ExecutableNotFound(path)
        }
    }

    private fun writeStdin(pipe: NSPipe, bytes: ByteArray) {
        val handle = pipe.fileHandleForWriting
        try {
            val data = bytes.usePinned { pinned ->
                NSData.dataWithBytes(pinned.addressOf(0), bytes.size.toULong())
            }
            handle.writeData(data)
        } finally {
            handle.closeFile()
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
