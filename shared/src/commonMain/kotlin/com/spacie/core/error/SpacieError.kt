package com.spacie.core.error

import kotlin.experimental.ExperimentalObjCName
import kotlin.native.ObjCName

@OptIn(ExperimentalObjCName::class)
@ObjCName("SpaSpacieError")
sealed class SpacieError(override val message: String) : Exception(message) {

    // -- Scan errors --

    @ObjCName("SpaSpacieErrorScanFailed")
    data class ScanFailed(val path: String, val reason: String) :
        SpacieError("Scan failed at $path: $reason")

    @ObjCName("SpaSpacieErrorScanCancelled")
    data class ScanCancelled(val reason: String) :
        SpacieError("Scan cancelled" + if (reason.isNotEmpty()) ": $reason" else "")

    @ObjCName("SpaSpacieErrorPathNotAccessible")
    data class PathNotAccessible(val path: String) :
        SpacieError("Path not accessible: $path")

    // -- Duplicate errors --

    @ObjCName("SpaSpacieErrorDuplicateReadFailed")
    data class DuplicateReadFailed(val path: String) :
        SpacieError("Failed to read: $path")

    @ObjCName("SpaSpacieErrorDuplicateCancelled")
    data object DuplicateCancelled :
        SpacieError("Duplicate scan cancelled")

    // -- iMobileDevice: Dependencies --

    @ObjCName("SpaSpacieErrorPackageManagerNotInstalled")
    data class PackageManagerNotInstalled(val managerName: String, val installUrl: String) :
        SpacieError("$managerName is not installed. Please install $managerName from $installUrl to continue.")

    @ObjCName("SpaSpacieErrorDependencyMissing")
    data class DependencyMissing(val tools: List<String>) :
        SpacieError("Required tools are not installed: ${tools.joinToString(", ")}.")

    @ObjCName("SpaSpacieErrorDependencyInstallFailed")
    data class DependencyInstallFailed(val reason: String) :
        SpacieError("Failed to install dependencies: $reason.")

    // -- iMobileDevice: Device --

    @ObjCName("SpaSpacieErrorDeviceNotFound")
    data class DeviceNotFound(val udid: String) :
        SpacieError("Device not found (UDID: $udid). Make sure the device is connected via USB.")

    @ObjCName("SpaSpacieErrorDeviceNotTrusted")
    data class DeviceNotTrusted(val udid: String, val name: String) :
        SpacieError("\"$name\" has not trusted this Mac. Tap \"Trust\" on the device when prompted.")

    @ObjCName("SpaSpacieErrorDeviceDisconnected")
    data class DeviceDisconnected(val udid: String, val during: String) :
        SpacieError("Device was disconnected during $during. Reconnect the device and try again.")

    // -- iMobileDevice: Parsing --

    @ObjCName("SpaSpacieErrorAppListParseFailed")
    data class AppListParseFailed(val reason: String, val rawOutput: String) :
        SpacieError("Failed to read the app list from the device: $reason.")

    // -- iMobileDevice: Extraction --

    @ObjCName("SpaSpacieErrorExtractionFailed")
    data class ExtractionFailed(val bundleID: String, val reason: String) :
        SpacieError("Failed to extract $bundleID: $reason.")

    // -- iMobileDevice: Installation --

    @ObjCName("SpaSpacieErrorInstallFailed")
    data class InstallFailed(val bundleID: String, val reason: String) :
        SpacieError("Failed to install $bundleID: $reason.")

    @ObjCName("SpaSpacieErrorIpaFileNotFound")
    data class IpaFileNotFound(val path: String) :
        SpacieError("IPA file not found at \"$path\".")

    // -- iMobileDevice: Process --

    @ObjCName("SpaSpacieErrorProcessExitedWithError")
    data class ProcessExitedWithError(val tool: String, val exitCode: Int, val stderr: String) :
        SpacieError("$tool exited with code $exitCode: ${if (stderr.length > 200) stderr.take(200) + "..." else stderr}")

    @ObjCName("SpaSpacieErrorProcessTimeout")
    data class ProcessTimeout(val tool: String, val timeout: Double) :
        SpacieError("$tool did not respond within ${timeout.toInt()} seconds.")

    // -- iMobileDevice: Control --

    @ObjCName("SpaSpacieErrorCancelled")
    data object Cancelled :
        SpacieError("The operation was cancelled.")

    // -- iMobileDevice: Authentication --

    @ObjCName("SpaSpacieErrorAuthFailed")
    data class AuthFailed(val reason: String) :
        SpacieError("Apple ID authentication failed: $reason.")

    @ObjCName("SpaSpacieErrorTwoFactorRequired")
    data object TwoFactorRequired :
        SpacieError("Apple sent a two-factor authentication code to your trusted devices. Enter the code to continue.")

    @ObjCName("SpaSpacieErrorNotAuthenticated")
    data object NotAuthenticated :
        SpacieError("Not signed in with Apple ID. Please sign in before downloading IPAs.")

    // -- iMobileDevice: Archive --

    @ObjCName("SpaSpacieErrorInsufficientDiskSpace")
    data class InsufficientDiskSpace(val required: Long, val available: Long) :
        SpacieError("Not enough disk space. Required: $required bytes, available: $available bytes.")

    @ObjCName("SpaSpacieErrorArchiveWriteFailed")
    data class ArchiveWriteFailed(val path: String, val reason: String) :
        SpacieError("Failed to write archive to \"$path\": $reason.")

    // -- Input Validation --

    @ObjCName("SpaSpacieErrorInvalidUDID")
    data class InvalidUDID(val udid: String) :
        SpacieError("Invalid UDID: \"$udid\" does not match [a-fA-F0-9-]{25,40}.")

    @ObjCName("SpaSpacieErrorInvalidBundleID")
    data class InvalidBundleID(val bundleID: String) :
        SpacieError("Invalid bundle ID: \"$bundleID\" is not a valid reverse-DNS identifier.")
}
