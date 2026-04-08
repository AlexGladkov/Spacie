package com.spacie.itransfer

import javax.swing.JFileChooser
import javax.swing.SwingUtilities

/**
 * Desktop implementation of folder picker using [JFileChooser].
 * Runs on the Event Dispatch Thread to keep Swing happy.
 */
actual fun pickFolder(): String? {
    var result: String? = null
    val latch = java.util.concurrent.CountDownLatch(1)

    SwingUtilities.invokeLater {
        val chooser = JFileChooser().apply {
            fileSelectionMode = JFileChooser.DIRECTORIES_ONLY
            dialogTitle = "Select Archive Folder"
            isAcceptAllFileFilterUsed = false
        }
        val returnCode = chooser.showOpenDialog(null)
        if (returnCode == JFileChooser.APPROVE_OPTION) {
            result = chooser.selectedFile.absolutePath
        }
        latch.countDown()
    }

    latch.await()
    return result
}
