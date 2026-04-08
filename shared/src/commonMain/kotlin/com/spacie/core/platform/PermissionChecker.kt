package com.spacie.core.platform

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

/**
 * Platform permission checker for macOS privacy settings.
 */
@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaPermissionChecker")
expect class PermissionChecker() {

    /**
     * Heuristically check whether Full Disk Access is granted.
     *
     * Probes well-known protected paths (Safari bookmarks, Mail, etc.)
     * to determine if the app has TCC Full Disk Access.
     *
     * @return true if Full Disk Access appears to be granted
     */
    fun checkFullDiskAccess(): Boolean

    /**
     * Open System Settings at the Full Disk Access pane.
     */
    fun openFullDiskAccessSettings()

    /**
     * Open System Settings at the Storage management pane.
     */
    fun openStorageSettings()
}
