package com.spacie.core.platform

import java.awt.Desktop
import java.net.URI

actual class PermissionChecker actual constructor() {

    /**
     * On JVM (Windows/Linux) there is no macOS TCC permission model.
     * Return true to indicate that no additional permission grant is needed.
     */
    actual fun checkFullDiskAccess(): Boolean = true

    /**
     * No-op on JVM — Full Disk Access is a macOS-only concept.
     */
    actual fun openFullDiskAccessSettings() {
        // No equivalent on Windows/Linux
    }

    /**
     * Open the system storage settings panel.
     * On Windows this navigates to the Storage Sense settings page.
     * On other platforms it is a no-op.
     */
    actual fun openStorageSettings() {
        val os = System.getProperty("os.name").orEmpty().lowercase()
        if (os.contains("win") && Desktop.isDesktopSupported()) {
            try {
                Desktop.getDesktop().browse(URI("ms-settings:storagesense"))
            } catch (_: Exception) {
                // Silently ignore — the settings URI may not be available in all environments
            }
        }
    }
}
