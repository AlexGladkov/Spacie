package com.spacie.core.engine

import java.security.MessageDigest

actual class Sha256Digest actual constructor() {

    private val digest: MessageDigest = MessageDigest.getInstance("SHA-256")

    actual fun update(data: ByteArray, offset: Int, length: Int) {
        digest.update(data, offset, length)
    }

    actual fun finalize(): ByteArray = digest.digest()
}
