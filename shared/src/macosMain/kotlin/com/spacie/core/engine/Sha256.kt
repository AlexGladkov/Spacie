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
        check(freed.value == 0) { "Sha256Digest already finalized" }
        if (length == 0) return
        data.usePinned { pinned ->
            CC_SHA256_Update(ctx.ptr, pinned.addressOf(offset), length.toUInt())
        }
    }

    actual fun finalize(): ByteArray {
        check(freed.value == 0) { "Sha256Digest already finalized" }
        val digest = ByteArray(32)
        digest.usePinned { pinned ->
            CC_SHA256_Final(pinned.addressOf(0).reinterpret(), ctx.ptr)
        }
        if (freed.compareAndSet(0, 1)) {
            nativeHeap.free(rawPtr)
        }
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
