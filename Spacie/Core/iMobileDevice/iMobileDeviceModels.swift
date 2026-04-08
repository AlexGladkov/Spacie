import Foundation

// MARK: - DeviceInfo

/// Represents a connected iOS device discovered via `idevice_id` or `idevicepair`.
///
/// The ``udid`` serves as the primary and stable identifier for a device across
/// connections. Human-readable properties (``deviceName``, ``productType``) are
/// populated from `ideviceinfo` output.
///
/// ## Example
/// ```swift
/// let device = DeviceInfo(
///     udid: "00008110-001A35E22EF8801E",
///     deviceName: "iPhone 15 Pro",
///     productType: "iPhone16,1",
///     productVersion: "18.3.1",
///     buildVersion: "22D72"
/// )
/// ```
struct DeviceInfo: Identifiable, Sendable, Hashable {

    /// Unique device identifier (40-char hex for USB, hyphenated for Wi-Fi).
    let udid: String

    /// User-assigned device name, e.g. "iPhone 15 Pro".
    let deviceName: String

    /// Apple internal model identifier, e.g. "iPhone16,1".
    let productType: String

    /// iOS version string, e.g. "18.3.1".
    let productVersion: String

    /// Build identifier, e.g. "22D72".
    let buildVersion: String

    var id: String { udid }
}

// MARK: - AppInfo

/// Metadata for an installed application on a connected iOS device.
///
/// Populated by parsing the plist output of `ideviceinstaller -l -o xml`.
/// The ``ipaSize`` is an estimate based on `StaticDiskUsage` reported by the device
/// and may differ from the actual extracted IPA size.
struct AppInfo: Identifiable, Sendable, Hashable {

    /// Bundle identifier, e.g. "com.apple.mobilesafari".
    let bundleID: String

    /// Localized display name shown on the Home Screen.
    let displayName: String

    /// `CFBundleVersion` -- build number.
    let version: String

    /// `CFBundleShortVersionString` -- marketing version.
    let shortVersion: String

    /// Estimated on-device size in bytes, if available.
    let ipaSize: UInt64?

    /// App icon PNG data (60x60pt), extracted from the device. `nil` if unavailable.
    let iconData: Data?

    var id: String { bundleID }
}

// MARK: - TrustState

/// Trust relationship state between the Mac and a connected iOS device.
///
/// Trust is required before any data transfer operations can proceed.
/// The host must be paired via `idevicepair pair`, which triggers the
/// "Trust This Computer?" dialog on the device.
enum TrustState: Sendable, Equatable {

    /// Device is connected but the host is not yet trusted.
    case notTrusted

    /// Trust dialog is currently displayed on the iPhone screen.
    ///
    /// Detected when `idevicepair` stderr contains
    /// `LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING`.
    case dialogShown

    /// Device has been paired and trusts this Mac.
    case trusted
}

// MARK: - DeviceEvent

/// Events emitted by the device monitor to track connection lifecycle.
///
/// Consumers should handle all cases to maintain an accurate device list
/// and react to trust changes or errors.
enum DeviceEvent: Sendable {

    /// A new device has been connected and its info has been read.
    case connected(DeviceInfo)

    /// A previously connected device has been disconnected.
    case disconnected(udid: String)

    /// The trust relationship for a device has changed.
    case trustStateChanged(udid: String, state: TrustState)

    /// An error occurred during device monitoring.
    case error(any Error)
}

// MARK: - ArchivedAppMetadata

/// Codable metadata stored alongside each archived IPA in the archive directory.
///
/// Persisted as `metadata.json` next to the IPA file. The app icon is stored
/// separately as `icon.png` in the same directory to keep the JSON compact.
struct ArchivedAppMetadata: Sendable, Codable {

    /// Bundle identifier of the archived app.
    let bundleID: String

    /// Localized display name at the time of archival.
    let displayName: String

    /// `CFBundleVersion` at the time of archival.
    let version: String

    /// `CFBundleShortVersionString` at the time of archival.
    let shortVersion: String

    /// Size of the IPA file in bytes.
    let ipaSize: UInt64

    /// Timestamp when the archive was created.
    let archivedAt: Date

    /// Name of the source device, if known. `nil` for manually imported archives.
    let sourceDeviceName: String?

    /// iOS version of the source device at archival time, if known.
    let sourceDeviceVersion: String?
}

// MARK: - ArchivedApp

/// An archived IPA with its metadata, ready for installation or export.
///
/// Each archive lives in its own UUID-named directory under the app's
/// support folder:
/// ```
/// ~/Library/Application Support/Spacie/Archives/<UUID>/
///     metadata.json
///     icon.png
///     <BundleID>.ipa
/// ```
struct ArchivedApp: Identifiable, Sendable {

    /// UUID string identifying the archive directory.
    let id: String

    /// Decoded metadata from `metadata.json`.
    let metadata: ArchivedAppMetadata

    /// File URL pointing to the IPA file on disk.
    let ipaURL: URL

    /// App icon PNG data loaded from `icon.png`. `nil` if the icon file is missing.
    let iconData: Data?

    /// Convenience accessor for the app's display name.
    var displayName: String { metadata.displayName }

    /// Convenience accessor for the bundle identifier.
    var bundleID: String { metadata.bundleID }
}

// MARK: - TransferPhase

/// Discrete phases of a single app transfer operation.
///
/// The phase progresses linearly: `pending` -> `extracting` -> `archiving` -> `completed`,
/// or short-circuits to `failed` at any point if an error occurs.
/// The `installing` phase is used only for device-to-device transfers that
/// include installation on a target device.
enum TransferPhase: Sendable, Equatable {

    /// Queued but not yet started.
    case pending

    /// Extracting the IPA from the source device via `ideviceinstaller`.
    case extracting

    /// Writing the extracted IPA and metadata to the archive directory.
    case archiving

    /// Installing the IPA on a target device.
    case installing

    /// Transfer completed successfully.
    case completed

    /// Transfer failed. See ``TransferItem/error`` for details.
    case failed
}

// MARK: - TransferItem

/// Tracks the transfer state of a single app within a batch operation.
///
/// Instances are value types and are replaced (not mutated in-place) as
/// the transfer progresses, ensuring safe snapshot semantics for the UI.
struct TransferItem: Identifiable, Sendable {

    /// Identifier matching the app's bundle ID.
    let id: String

    /// Source app metadata.
    let app: AppInfo

    /// Current transfer phase.
    var phase: TransferPhase = .pending

    /// Fractional progress within the current phase, from 0.0 to 1.0.
    var progress: Double = 0.0

    /// Error that caused a failure, if ``phase`` is ``TransferPhase/failed``.
    var error: iMobileDeviceError?
}

// MARK: - TransferProgress

/// Aggregate progress snapshot for a batch transfer operation.
///
/// Published by the transfer coordinator to drive the progress UI.
/// All computed properties are O(n) where n is ``totalCount``.
struct TransferProgress: Sendable {

    /// Ordered list of all items in this batch.
    let items: [TransferItem]

    /// Zero-based index of the item currently being processed.
    let currentItemIndex: Int

    /// Number of items that have completed successfully.
    var completedCount: Int {
        items.filter { $0.phase == .completed }.count
    }

    /// Number of items that have failed.
    var failedCount: Int {
        items.filter { $0.phase == .failed }.count
    }

    /// Total number of items in the batch.
    var totalCount: Int { items.count }

    /// Overall batch progress as a fraction from 0.0 to 1.0.
    ///
    /// Calculated as the ratio of finished items (completed + failed) to total items.
    /// Returns 0 if the batch is empty.
    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount + failedCount) / Double(totalCount)
    }
}

// MARK: - TransferItemResult

/// Final outcome of transferring a single app.
struct TransferItemResult: Identifiable, Sendable {

    /// Identifier matching the app's bundle ID.
    let id: String

    /// Source app metadata.
    let app: AppInfo

    /// Whether the transfer completed without errors.
    let success: Bool

    /// File URL of the archived IPA, if the transfer succeeded.
    let archivedURL: URL?

    /// Error that caused the failure, if ``success`` is `false`.
    let error: iMobileDeviceError?
}

// MARK: - TransferResult

/// Aggregate outcome for a completed batch transfer.
struct TransferResult: Sendable {

    /// Results for every item in the batch, in original order.
    let items: [TransferItemResult]

    /// Number of successfully transferred apps.
    var successCount: Int {
        items.filter(\.success).count
    }

    /// Number of apps that failed to transfer.
    var failureCount: Int {
        items.filter { !$0.success }.count
    }
}

// MARK: - iMobileDeviceError

/// Errors originating from iMobileDevice CLI tool interactions.
///
/// Each case captures enough context for both user-facing messages and
/// diagnostic logging. All associated values are `Sendable`-safe.
enum iMobileDeviceError: Error, LocalizedError, Sendable {

    // MARK: Dependencies

    /// Homebrew is not installed or not found in PATH.
    case homebrewNotInstalled

    /// One or more required CLI tools are missing.
    case dependencyMissing([String])

    /// `brew install` or equivalent failed.
    case dependencyInstallFailed(reason: String)

    // MARK: Device

    /// No device with the given UDID is currently connected.
    case deviceNotFound(udid: String)

    /// The device is connected but has not trusted this Mac.
    case deviceNotTrusted(udid: String, name: String)

    /// The device was disconnected during an active operation.
    case deviceDisconnected(udid: String, during: String)

    // MARK: Parsing

    /// Failed to parse the installed app list from `ideviceinstaller` output.
    case appListParseFailed(reason: String, rawOutput: String)

    // MARK: Extraction

    /// IPA extraction from the device failed.
    case extractionFailed(bundleID: String, reason: String)

    // MARK: Installation

    /// IPA installation on the target device failed.
    case installFailed(bundleID: String, reason: String)

    /// The IPA file expected at the given path does not exist.
    case ipaFileNotFound(path: String)

    // MARK: Process

    /// A CLI tool exited with a non-zero status.
    case processExitedWithError(tool: String, exitCode: Int32, stderr: String)

    /// A CLI tool did not complete within the allowed time.
    case processTimeout(tool: String, timeout: TimeInterval)

    // MARK: Control

    /// The operation was cancelled by the user or system.
    case cancelled

    // MARK: Authentication

    /// Apple ID authentication via ipatool failed.
    case authFailed(reason: String)

    /// Apple ID authentication requires a two-factor verification code.
    /// The caller should prompt the user for the code and retry with ``loginAppleID``.
    case twoFactorRequired

    /// An operation requires Apple ID authentication but ipatool is not signed in.
    case notAuthenticated

    // MARK: Archive

    /// Not enough free disk space to write the archive.
    case insufficientDiskSpace(required: UInt64, available: UInt64)

    /// Failed to write archive data to disk.
    case archiveWriteFailed(path: String, reason: String)

    // MARK: LocalizedError

    var errorDescription: String? {
        switch self {
        case .homebrewNotInstalled:
            return "Homebrew is not installed. Please install Homebrew from https://brew.sh to continue."

        case .dependencyMissing(let tools):
            let list = tools.joined(separator: ", ")
            return "Required tools are not installed: \(list)."

        case .dependencyInstallFailed(let reason):
            return "Failed to install dependencies: \(reason)."

        case .deviceNotFound(let udid):
            return "Device not found (UDID: \(udid)). Make sure the device is connected via USB."

        case .deviceNotTrusted(_, let name):
            return "\"\(name)\" has not trusted this Mac. Tap \"Trust\" on the device when prompted."

        case .deviceDisconnected(_, let during):
            return "Device was disconnected during \(during). Reconnect the device and try again."

        case .appListParseFailed(let reason, _):
            return "Failed to read the app list from the device: \(reason)."

        case .extractionFailed(let bundleID, let reason):
            return "Failed to extract \(bundleID): \(reason)."

        case .installFailed(let bundleID, let reason):
            return "Failed to install \(bundleID): \(reason)."

        case .ipaFileNotFound(let path):
            return "IPA file not found at \"\(path)\"."

        case .processExitedWithError(let tool, let exitCode, let stderr):
            let truncatedStderr = stderr.count > 200 ? String(stderr.prefix(200)) + "..." : stderr
            return "\(tool) exited with code \(exitCode): \(truncatedStderr)"

        case .processTimeout(let tool, let timeout):
            return "\(tool) did not respond within \(Int(timeout)) seconds."

        case .cancelled:
            return "The operation was cancelled."

        case .insufficientDiskSpace(let required, let available):
            return "Not enough disk space. Required: \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file)), available: \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file))."

        case .archiveWriteFailed(let path, let reason):
            return "Failed to write archive to \"\(path)\": \(reason)."

        case .authFailed(let reason):
            return "Apple ID authentication failed: \(reason)."

        case .twoFactorRequired:
            return "Apple sent a two-factor authentication code to your trusted devices. Enter the code to continue."

        case .notAuthenticated:
            return "Not signed in with Apple ID. Please sign in before downloading IPAs."
        }
    }
}
