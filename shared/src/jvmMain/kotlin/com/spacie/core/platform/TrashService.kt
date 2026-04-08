package com.spacie.core.platform

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.awt.Desktop
import java.io.File

actual class TrashService actual constructor() {

    actual suspend fun moveToTrash(path: String): String = withContext(Dispatchers.IO) {
        val file = File(path)
        if (!file.exists()) throw Exception("File not found: $path")

        if (Desktop.isDesktopSupported() &&
            Desktop.getDesktop().isSupported(Desktop.Action.MOVE_TO_TRASH)
        ) {
            val moved = Desktop.getDesktop().moveToTrash(file)
            if (!moved) throw Exception("Failed to move to trash: $path")
        } else {
            // Fallback for headless or unsupported environments
            file.deleteRecursively()
        }
        path
    }

    actual suspend fun moveToTrashBatch(paths: List<String>): List<TrashItemResult> =
        withContext(Dispatchers.IO) {
            paths.map { path ->
                try {
                    moveToTrash(path)
                    TrashItemResult(
                        originalPath = path,
                        success = true,
                        trashPath = null,
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

    actual suspend fun trashSize(): Long = withContext(Dispatchers.IO) {
        // Trash size detection is highly platform-specific on JVM.
        // On Windows: $Recycle.Bin per drive; on Linux: ~/.local/share/Trash
        // Return 0 as a safe default — determining exact trash size requires
        // OS-specific enumeration that is out of scope for the JVM target.
        0L
    }
}
