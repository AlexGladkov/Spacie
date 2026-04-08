package com.spacie.core.platform

import platform.AppKit.NSWorkspace
import platform.Foundation.NSFileManager
import platform.Foundation.NSHomeDirectory
import platform.Foundation.NSURL
import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaPermissionChecker")
actual class PermissionChecker actual constructor() {

    /**
     * Probe well-known TCC-protected paths to determine Full Disk Access.
     *
     * Strategy: if any protected file exists but is NOT readable,
     * FDA is not granted. If all probes are readable (or absent), assume granted.
     */
    actual fun checkFullDiskAccess(): Boolean {
        val fm = NSFileManager.defaultManager
        val homeDir = NSHomeDirectory()

        val probePaths = listOf(
            "$homeDir/Library/Safari/Bookmarks.plist",
            "$homeDir/Library/Safari/CloudTabs.db",
            "$homeDir/Library/Mail"
        )

        for (path in probePaths) {
            if (!fm.fileExistsAtPath(path)) continue
            // File exists -- check readability
            if (!fm.isReadableFileAtPath(path)) {
                return false
            }
        }

        // All existing probe paths are readable, or none exist
        return true
    }

    actual fun openFullDiskAccessSettings() {
        val url = NSURL.URLWithString(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) ?: return
        NSWorkspace.sharedWorkspace.openURL(url)
    }

    actual fun openStorageSettings() {
        val url = NSURL.URLWithString(
            "x-apple.systempreferences:com.apple.settings.Storage"
        ) ?: return
        NSWorkspace.sharedWorkspace.openURL(url)
    }
}
