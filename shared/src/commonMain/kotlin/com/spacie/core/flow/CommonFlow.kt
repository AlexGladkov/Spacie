package com.spacie.core.flow

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlin.concurrent.AtomicInt

/**
 * Handle returned by [CommonFlow.watch] / [CommonStateFlow.watch].
 *
 * **Callers MUST invoke [close]** when the subscription is no longer needed.
 * Failing to call [close] leaks the underlying coroutine scope (one
 * `SupervisorJob` per `watch()` invocation) and keeps the upstream flow
 * collecting forever.
 *
 * Calling [close] more than once is safe — additional calls are no-ops.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCloseable")
interface Closeable {
    fun close()
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCommonFlow")
class CommonFlow<T>(private val origin: Flow<T>) : Flow<T> by origin {
    /**
     * Subscribe [block] to the underlying flow. The returned [Closeable] owns
     * the subscription's coroutine scope — **call [Closeable.close] to release
     * it**; otherwise the scope (and therefore this watcher) leaks for the
     * lifetime of the process.
     */
    fun watch(block: (T) -> Unit): Closeable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        origin.onEach { block(it) }.launchIn(scope)
        return ScopeCloseable(scope)
    }
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCommonStateFlow")
class CommonStateFlow<T>(private val origin: StateFlow<T>) {

    /** Snapshot of the latest emitted value. */
    val value: T
        get() = origin.value

    /**
     * Subscribe [block] to the underlying state flow. See [CommonFlow.watch]
     * — the same close-or-leak rule applies.
     *
     * The implementation eagerly delivers the current value (StateFlow's
     * replay-1 semantics) on first emission.
     */
    fun watch(block: (T) -> Unit): Closeable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        origin.onEach { block(it) }.launchIn(scope)
        return ScopeCloseable(scope)
    }
}

fun <T> Flow<T>.asCommonFlow(): CommonFlow<T> = CommonFlow(this)
fun <T> StateFlow<T>.asCommonStateFlow(): CommonStateFlow<T> = CommonStateFlow(this)

/**
 * [Closeable] wrapping a [CoroutineScope] with idempotent [close]:
 * additional invocations after the first are no-ops, eliminating the
 * "did we call close twice?" foot-gun on the Swift side.
 */
private class ScopeCloseable(private val scope: CoroutineScope) : Closeable {
    // AtomicInt.compareAndSet provides the TOCTOU-safe claim that the
    // documented "additional calls are no-ops" guarantee requires. `@Volatile`
    // alone gives only visibility, not atomicity — two threads could both
    // observe 0, both write 1, and both invoke `scope.cancel()`. Today that
    // happens to be idempotent, but any future resource we add to `close()`
    // would be double-released.
    private val closed = AtomicInt(0)

    override fun close() {
        if (!closed.compareAndSet(0, 1)) return
        scope.cancel()
    }
}
