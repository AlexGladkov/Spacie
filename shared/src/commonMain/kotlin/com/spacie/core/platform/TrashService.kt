package com.spacie.core.platform

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Result of moving a single item to the Trash.
 *
 * @property originalPath the path that was requested to be trashed
 * @property success whether the operation succeeded
 * @property trashPath the new path inside Trash (null on failure)
 * @property errorMessage human-readable error description (null on success)
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTrashItemResult")
data class TrashItemResult(
    val originalPath: String,
    val success: Boolean,
    val trashPath: String?,
    val errorMessage: String?
)

/**
 * Platform Trash service. Moves files to the system Trash and queries Trash size.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaTrashService")
expect class TrashService() {

    /**
     * Move a single item to the system Trash.
     *
     * @param path absolute path of the item to trash
     * @return the new path of the item inside the Trash
     * @throws Exception if the operation fails
     */
    suspend fun moveToTrash(path: String): String

    /**
     * Move multiple items to the Trash in batch.
     *
     * Never throws; individual failures are captured in [TrashItemResult].
     *
     * @param paths list of absolute paths to trash
     * @return per-item results
     */
    suspend fun moveToTrashBatch(paths: List<String>): List<TrashItemResult>

    /**
     * Calculate the total size of the current user's Trash directory.
     *
     * @return size in bytes
     */
    suspend fun trashSize(): Long
}
