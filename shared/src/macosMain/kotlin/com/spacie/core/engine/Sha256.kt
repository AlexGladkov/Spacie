package com.spacie.core.engine

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.free
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import platform.CoreCrypto.CC_SHA256_CTX
import platform.CoreCrypto.CC_SHA256_Final
import platform.CoreCrypto.CC_SHA256_Init
import platform.CoreCrypto.CC_SHA256_Update

@OptIn(ExperimentalForeignApi::class)
actual class Sha256Digest actual constructor() {
    private val ctx = nativeHeap.alloc<CC_SHA256_CTX>()

    init {
        CC_SHA256_Init(ctx.ptr)
    }

    actual fun update(data: ByteArray, offset: Int, length: Int) {
        data.usePinned { pinned ->
            CC_SHA256_Update(ctx.ptr, pinned.addressOf(offset), length.toUInt())
        }
    }

    actual fun finalize(): ByteArray {
        val digest = ByteArray(32)
        digest.usePinned { pinned ->
            CC_SHA256_Final(pinned.addressOf(0).reinterpret(), ctx.ptr)
        }
        nativeHeap.free(ctx.rawPtr)
        return digest
    }
}
