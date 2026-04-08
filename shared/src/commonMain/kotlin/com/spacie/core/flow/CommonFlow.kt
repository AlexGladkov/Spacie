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

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCloseable")
interface Closeable {
    fun close()
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCommonFlow")
class CommonFlow<T>(private val origin: Flow<T>) : Flow<T> by origin {
    fun watch(block: (T) -> Unit): Closeable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        origin.onEach { block(it) }.launchIn(scope)
        return object : Closeable {
            override fun close() {
                scope.cancel()
            }
        }
    }
}

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaCommonStateFlow")
class CommonStateFlow<T>(private val origin: StateFlow<T>) : StateFlow<T> by origin {
    fun watch(block: (T) -> Unit): Closeable {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        origin.onEach { block(it) }.launchIn(scope)
        return object : Closeable {
            override fun close() {
                scope.cancel()
            }
        }
    }
}

fun <T> Flow<T>.asCommonFlow(): CommonFlow<T> = CommonFlow(this)
fun <T> StateFlow<T>.asCommonStateFlow(): CommonStateFlow<T> = CommonStateFlow(this)
