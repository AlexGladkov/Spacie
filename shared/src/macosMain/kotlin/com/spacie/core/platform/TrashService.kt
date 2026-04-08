@file:OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)

package com.spacie.core.platform

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.NSError
import platform.Foundation.NSFileManager
import platform.Foundation.NSFileSize
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSNumber
import platform.Foundation.NSURL
import platform.darwin.DISPATCH_QUEUE_PRIORITY_DEFAULT
import platform.darwin.DISPATCH_QUEUE_PRIORITY_BACKGROUND
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_global_queue
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTrashService")
actual class TrashService actual constructor() {

    actual suspend fun moveToTrash(path: String): String {
        return suspendCancellableCoroutine { cont ->
            val queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT.toLong(), 0u)
            dispatch_async(queue) {
                val fm = NSFileManager.defaultManager
                val url = NSURL.fileURLWithPath(path)

                memScoped {
                    val errorPtr = alloc<ObjCObjectVar<NSError?>>()
                    val resultPtr = alloc<ObjCObjectVar<NSURL?>>()

                    val success = fm.trashItemAtURL(
                        url,
                        resultingItemURL = resultPtr.ptr,
                        error = errorPtr.ptr
                    )

                    if (success) {
                        val resultPath = resultPtr.value?.path ?: path
                        cont.resume(resultPath)
                    } else {
                        val msg = errorPtr.value?.localizedDescription ?: "Unknown trash error"
                        cont.resumeWithException(Exception("TrashError[$path]: $msg"))
                    }
                }
            }
        }
    }

    actual suspend fun moveToTrashBatch(paths: List<String>): List<TrashItemResult> {
        return paths.map { path ->
            try {
                val trashPath = moveToTrash(path)
                TrashItemResult(
                    originalPath = path,
                    success = true,
                    trashPath = trashPath,
                    errorMessage = null
                )
            } catch (e: Exception) {
                TrashItemResult(
                    originalPath = path,
                    success = false,
                    trashPath = null,
                    errorMessage = e.message
                )
            }
        }
    }

    actual suspend fun trashSize(): Long {
        return suspendCancellableCoroutine { cont ->
            val queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND.toLong(), 0u)
            dispatch_async(queue) {
                val trashPath = "${NSHomeDirectory()}/.Trash"
                val fm = NSFileManager.defaultManager

                if (!fm.fileExistsAtPath(trashPath)) {
                    cont.resume(0L)
                    return@dispatch_async
                }

                var totalSize = 0L
                val enumerator = fm.enumeratorAtPath(trashPath)
                if (enumerator != null) {
                    while (true) {
                        val item = enumerator.nextObject() as? String ?: break
                        val fullPath = "$trashPath/$item"
                        val attrs = fm.attributesOfItemAtPath(fullPath, error = null)
                        if (attrs != null) {
                            val size = (attrs[NSFileSize] as? NSNumber)?.longLongValue ?: 0L
                            totalSize += size
                        }
                    }
                }

                cont.resume(totalSize)
            }
        }
    }
}
