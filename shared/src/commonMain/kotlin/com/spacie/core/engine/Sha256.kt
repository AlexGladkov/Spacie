package com.spacie.core.engine

expect class Sha256Digest() {
    fun update(data: ByteArray, offset: Int, length: Int)
    fun finalize(): ByteArray
}
