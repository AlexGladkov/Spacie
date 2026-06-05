package com.spacie.core.engine

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.NativePtr
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.free
import kotlinx.cinterop.interpretCPointer
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CC_SHA256_CTX
import platform.CoreCrypto.CC_SHA256_Final
import platform.CoreCrypto.CC_SHA256_Init
import platform.CoreCrypto.CC_SHA256_Update
import kotlin.concurrent.AtomicInt
import kotlin.experimental.ExperimentalNativeApi
import kotlin.native.ref.createCleaner

/**
 * Single-thread, single-owner SHA-256 streaming digest.
 *
 * ## Thread-safety contract
 *
 * `Sha256Digest` is **NOT thread-safe**. A given instance MUST be used by one
 * thread (or one structured-concurrency context) at a time. Calling
 * [update] and [finalize] concurrently, or [update] after [finalize] has
 * started on another thread, is undefined behaviour and can use-after-free
 * the underlying native CC_SHA256_CTX allocation.
 *
 * The [finalize] CAS protects against double-free between an explicit call
 * and the [Cleaner]-driven [FreeAction]; it does NOT serialise concurrent
 * [update] calls. Callers must enforce single-ownership themselves (e.g. by
 * keeping the digest inside a single coroutine or behind a Mutex).
 */
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
actual class Sha256Digest actual constructor() {

    private val ctx = nativeHeap.alloc<CC_SHA256_CTX>()
    private val rawPtr: NativePtr = ctx.rawPtr
    private val freed = AtomicInt(0)

    @Suppress("unused")
    private val cleaner = createCleaner(FreeAction(rawPtr, freed)) { action ->
        action.invoke()
    }

    init {
        CC_SHA256_Init(ctx.ptr)
    }

    actual fun update(data: ByteArray, offset: Int, length: Int) {
        // Atomic read is sufficient as long as the caller observes the
        // single-thread contract documented at the class level. If two
        // threads race update vs. finalize anyway, this surface check at
        // least throws on the loser most of the time; it cannot make
        // concurrent CC_SHA256_Update safe (would require a Mutex).
        check(freed.value == 0) { "Sha256Digest already finalized" }
        if (length == 0) return
        data.usePinned { pinned ->
            CC_SHA256_Update(ctx.ptr, pinned.addressOf(offset), length.toUInt())
        }
    }

    actual fun finalize(): ByteArray {
        // Claim ownership FIRST via CAS — guarantees exactly one thread runs
        // CC_SHA256_Final + nativeHeap.free, and that the Cleaner-driven free
        // path (FreeAction below) will lose its own CAS and skip the free.
        // Without the early CAS, two concurrent finalize() calls would both
        // pass `check(freed == 0)`, both run CC_SHA256_Final on the same C
        // struct (data race on native heap), and race to free the allocation.
        if (!freed.compareAndSet(0, 1)) {
            throw IllegalStateException("Sha256Digest already finalized")
        }
        val digest = ByteArray(32)
        digest.usePinned { pinned ->
            CC_SHA256_Final(pinned.addressOf(0).reinterpret(), ctx.ptr)
        }
        nativeHeap.free(rawPtr)
        return digest
    }

    private class FreeAction(
        private val ptr: NativePtr,
        private val freed: AtomicInt
    ) {
        fun invoke() {
            if (freed.compareAndSet(0, 1)) {
                nativeHeap.free(ptr)
            }
        }
    }
}
