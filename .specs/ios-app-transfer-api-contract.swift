// ============================================================================
// iOS App Transfer — API Contract (Design Only, No Implementation)
// ============================================================================
//
// Spacie / Core / iMobileDevice
//
// Swift 6, macOS 15+, Strict Concurrency
// Follows existing Spacie patterns: @Observable, AsyncStream, enum state machines,
// Sendable models, protocol-based testability.
//
// Date: 2026-04-06
// Status: API Design — ready for review
// ============================================================================

import Foundation

// MARK: - 1. Domain Models

// MARK: DeviceInfo

/// Represents a connected iOS device discovered via libimobiledevice.
///
/// Populated from `idevice_id -l` (UDID discovery) and enriched by
/// `ideviceinfo -u <UDID>` (name, model, iOS version).
struct DeviceInfo: Identifiable, Sendable, Hashable {
    /// Unique Device Identifier (40-char hex for pre-iPhone X, 24-char + hyphen for newer).
    let udid: String
    /// User-assigned device name (e.g. "iPhone Artyom").
    let deviceName: String
    /// Internal hardware model (e.g. "iPhone16,1").
    let productType: String
    /// iOS version string (e.g. "18.3.1").
    let productVersion: String
    /// Device class: "iPhone", "iPad", "iPod".
    let deviceClass: String

    var id: String { udid }

    /// User-facing summary: "iPhone 15 Pro (iOS 18.3.1)".
    /// Marketing name resolution is handled by the presentation layer.
    var displaySummary: String {
        "\(deviceName) (\(deviceClass), iOS \(productVersion))"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(udid) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.udid == rhs.udid }
}

// MARK: AppInfo

/// Represents a single installed application on an iOS device.
///
/// Parsed from the plist output of `ideviceinstaller -u <UDID> -l -o xml`.
/// The plist is an array of dictionaries; each dictionary contains keys like
/// `CFBundleIdentifier`, `CFBundleDisplayName`, `CFBundleShortVersionString`,
/// `StaticDiskUsage`, `DynamicDiskUsage`.
struct AppInfo: Identifiable, Sendable, Hashable {
    /// Bundle identifier (e.g. "com.sberbank.online").
    let bundleID: String
    /// User-visible display name (e.g. "SberBank"). Falls back to CFBundleName.
    let displayName: String
    /// Short version string (e.g. "15.3.1").
    let version: String
    /// Build number if available (e.g. "2024031901").
    let buildNumber: String?
    /// On-device static disk usage in bytes (the .app bundle itself).
    let staticDiskUsage: UInt64
    /// On-device dynamic disk usage in bytes (Documents, Library, tmp).
    let dynamicDiskUsage: UInt64
    /// Signer identity — "Apple iPhone OS Application Signing" for App Store apps.
    let signerIdentity: String?

    var id: String { bundleID }

    /// Total size = static + dynamic.
    var totalSize: UInt64 { staticDiskUsage + dynamicDiskUsage }

    /// Whether this is a system/Apple app (not extractable).
    var isSystemApp: Bool {
        signerIdentity == nil || bundleID.hasPrefix("com.apple.")
    }

    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bundleID == rhs.bundleID }
}

// MARK: DeviceEvent

/// Events emitted by the device polling stream.
///
/// Used by `waitForDevice()` → `AsyncStream<DeviceEvent>`. The polling
/// mechanism runs `idevice_id -l` every N seconds and diffs against the
/// previous set of known UDIDs.
enum DeviceEvent: Sendable {
    /// A new device was connected (UDID first seen).
    case connected(DeviceInfo)
    /// A previously known device was disconnected (UDID disappeared).
    case disconnected(udid: String)
    /// Polling encountered a non-fatal error (e.g. idevice_id returned exit code != 0).
    /// Polling continues after this event.
    case error(iMobileDeviceError)
}

// MARK: TransferItem

/// Tracks the state of a single app being transferred (extracted + installed).
///
/// The ViewModel holds an array of `TransferItem` to drive the per-app
/// progress UI. Each item progresses through phases independently.
struct TransferItem: Identifiable, Sendable {
    let id: String // bundleID
    let app: AppInfo
    var phase: TransferPhase
    var progress: Double // 0.0 ... 1.0 within current phase
    var error: iMobileDeviceError?
    /// Path to the extracted .ipa on disk (set after extraction completes).
    var localIPAPath: URL?

    /// Whether this item completed successfully (both extract + install).
    var isCompleted: Bool {
        if case .completed = phase { return true }
        return false
    }

    /// Whether this item has failed.
    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}

// MARK: TransferPhase

/// Discrete phases of a single app transfer.
///
/// State machine per app:
/// ```
/// waiting -> extracting -> extracted -> installing -> completed
///                |                          |
///                v                          v
///             failed                     failed
/// ```
enum TransferPhase: Sendable, Equatable {
    /// Queued, not yet started.
    case waiting
    /// Extracting .ipa from source device. Progress = bytes extracted / total.
    case extracting
    /// .ipa extracted to local disk, ready for install or archive.
    case extracted
    /// Installing .ipa on destination device.
    case installing
    /// Successfully installed on destination.
    case completed
    /// Failed at any stage. Reason in `TransferItem.error`.
    case failed(String)
}

// MARK: TransferProgress

/// Aggregate progress across all apps in a transfer session.
///
/// Emitted through `AsyncStream<TransferProgress>` from the service layer.
/// The ViewModel can use this or derive it from the array of TransferItems.
struct TransferProgress: Sendable {
    /// Total number of apps selected for transfer.
    let totalApps: Int
    /// Number of apps completed (success or failure).
    let completedApps: Int
    /// Number of apps that failed.
    let failedApps: Int
    /// Currently active app being processed (nil if all done).
    let currentApp: AppInfo?
    /// Phase of the currently active app.
    let currentPhase: TransferPhase?
    /// Progress within the current app's current phase (0.0 ... 1.0).
    let currentAppProgress: Double
    /// Total bytes written to disk so far across all apps.
    let bytesTransferred: UInt64
    /// Estimated total bytes (sum of selected apps' staticDiskUsage).
    let bytesTotal: UInt64

    var overallFraction: Double {
        guard totalApps > 0 else { return 0 }
        let completed = Double(completedApps)
        let partial = currentAppProgress
        return (completed + partial) / Double(totalApps)
    }

    var isFinished: Bool { completedApps + failedApps >= totalApps }
}

// MARK: TransferResult

/// Final result of a completed transfer session.
struct TransferResult: Sendable {
    let items: [TransferItemResult]
    let duration: TimeInterval

    var successCount: Int { items.filter(\.success).count }
    var failureCount: Int { items.filter { !$0.success }.count }
}

/// Result for a single app in a transfer session.
struct TransferItemResult: Identifiable, Sendable {
    let id: String // bundleID
    let app: AppInfo
    let success: Bool
    let error: iMobileDeviceError?
    /// Path to archived .ipa (if archive was enabled and extraction succeeded).
    let archivedIPAPath: URL?
}

// MARK: - 2. Error Types

// MARK: iMobileDeviceError

/// Comprehensive error type for all iMobileDevice operations.
///
/// Follows the existing Spacie pattern (see `TrashError`, `DuplicateEngineError`):
/// - enum with associated values for context
/// - Conforms to LocalizedError for user-facing messages
/// - Conforms to Sendable for Swift 6 concurrency
///
/// Error codes are grouped by operation domain. Each case carries enough
/// context for the UI layer to present actionable guidance.
enum iMobileDeviceError: LocalizedError, Sendable {

    // --- Dependency errors ---

    /// Homebrew is not installed on this system.
    /// UI action: show link to brew.sh + manual install instructions.
    case homebrewNotInstalled

    /// One or more required CLI tools are missing.
    /// `missingTools` lists the specific binaries not found in PATH.
    /// UI action: offer "Install automatically" via Terminal or show manual command.
    case dependencyMissing(missingTools: [String])

    /// Dependency installation was attempted but failed.
    case dependencyInstallFailed(tool: String, reason: String)

    // --- Device errors ---

    /// No device found with the given UDID. It may have been disconnected.
    case deviceNotFound(udid: String)

    /// The device is visible but has not been trusted by the user.
    /// UI action: show Trust instructions sheet with step-by-step guide.
    case deviceNotTrusted(udid: String, deviceName: String?)

    /// The device was disconnected during an operation.
    /// `during` describes what was in progress (e.g. "extracting com.sberbank.online").
    case deviceDisconnected(udid: String, during: String)

    /// The device returned an unexpected error from a CLI command.
    case deviceError(udid: String, message: String)

    // --- App listing errors ---

    /// Failed to parse the plist output from ideviceinstaller -l.
    /// `rawOutput` is truncated to first 500 chars for diagnostics.
    case appListParseFailed(reason: String, rawOutput: String?)

    // --- Extraction errors ---

    /// IPA extraction failed for the given bundle ID.
    /// Possible causes: app is DRM-protected, disk full, permission denied.
    case extractionFailed(bundleID: String, reason: String)

    /// The `ideviceinstaller --extract` command is not supported in the
    /// installed version. The service should attempt ifuse fallback.
    case extractionNotSupported

    /// ifuse is required as fallback but not installed.
    case ifuseNotInstalled

    // --- Installation errors ---

    /// IPA installation failed on the destination device.
    /// Common cause: FairPlay DRM mismatch (different Apple IDs).
    case installFailed(bundleID: String, reason: String)

    /// The .ipa file at the given path does not exist or is unreadable.
    case ipaFileNotFound(path: String)

    // --- Process errors ---

    /// The CLI process exited with a non-zero exit code.
    /// Carries the full stderr output for diagnostics.
    case processExitedWithError(tool: String, exitCode: Int32, stderr: String)

    /// The CLI process timed out after the specified duration.
    case processTimeout(tool: String, timeout: TimeInterval)

    // --- Cancellation ---

    /// The operation was cancelled by the user.
    case cancelled

    // --- Archive errors ---

    /// Not enough disk space to save the .ipa archive.
    case insufficientDiskSpace(required: UInt64, available: UInt64)

    /// Failed to write to the archive directory.
    case archiveWriteFailed(path: String, reason: String)

    // MARK: LocalizedError

    var errorDescription: String? {
        switch self {
        case .homebrewNotInstalled:
            "Homebrew is not installed. Install it from https://brew.sh"
        case .dependencyMissing(let tools):
            "Required tools not found: \(tools.joined(separator: ", "))"
        case .dependencyInstallFailed(let tool, let reason):
            "Failed to install \(tool): \(reason)"
        case .deviceNotFound(let udid):
            "Device \(udid.prefix(8))... not found. Check USB connection."
        case .deviceNotTrusted(_, let name):
            "Device \(name ?? "Unknown") has not been trusted. Tap 'Trust' on the device."
        case .deviceDisconnected(_, let during):
            "Device disconnected during \(during)"
        case .deviceError(_, let message):
            "Device error: \(message)"
        case .appListParseFailed(let reason, _):
            "Failed to read app list: \(reason)"
        case .extractionFailed(let bundleID, let reason):
            "Failed to extract \(bundleID): \(reason)"
        case .extractionNotSupported:
            "IPA extraction not supported by installed ideviceinstaller version"
        case .ifuseNotInstalled:
            "ifuse is required for IPA extraction but is not installed"
        case .installFailed(let bundleID, let reason):
            "Failed to install \(bundleID): \(reason)"
        case .ipaFileNotFound(let path):
            "IPA file not found: \(path)"
        case .processExitedWithError(let tool, let code, _):
            "\(tool) exited with code \(code)"
        case .processTimeout(let tool, let timeout):
            "\(tool) timed out after \(Int(timeout))s"
        case .cancelled:
            "Operation cancelled"
        case .insufficientDiskSpace(let required, let available):
            "Not enough disk space: need \(required) bytes, have \(available) bytes"
        case .archiveWriteFailed(let path, let reason):
            "Failed to write archive at \(path): \(reason)"
        }
    }
}

// MARK: - 3. Dependency Models

// MARK: DependencyStatus

/// Result of checking whether required CLI tools are available.
///
/// Checked at the start of the iTransfer flow (Step 0).
/// Each tool is resolved via `which <tool>` or checking known Homebrew paths.
enum DependencyStatus: Sendable, Equatable {
    /// All required tools are available. Ready to proceed.
    case ready(ToolPaths)
    /// Some tools are missing. Lists which ones need installation.
    case missing(missingTools: [String])
    /// Homebrew itself is not installed (prerequisite for everything).
    case homebrewMissing
}

/// Resolved absolute paths to CLI tools.
///
/// Cached after successful dependency check to avoid repeated `which` calls.
/// Paths are validated once; if a tool disappears mid-session, the Process
/// wrapper will surface a `processExitedWithError`.
struct ToolPaths: Sendable, Equatable {
    /// Path to `idevice_id` (e.g. "/opt/homebrew/bin/idevice_id").
    let ideviceId: String
    /// Path to `ideviceinfo` (e.g. "/opt/homebrew/bin/ideviceinfo").
    let ideviceInfo: String
    /// Path to `ideviceinstaller` (e.g. "/opt/homebrew/bin/ideviceinstaller").
    let ideviceInstaller: String
    /// Path to `ifuse` if available (fallback for extraction). Nil if not installed.
    let ifuse: String?
}

// MARK: - 4. Protocol: iMobileDeviceProtocol

/// Service-layer abstraction over libimobiledevice CLI tools.
///
/// ## Design Rationale
///
/// **Why a protocol, not a concrete class?**
/// 1. Testability — `MockiMobileDeviceService` can simulate devices, errors,
///    and timing without USB hardware.
/// 2. Preview support — SwiftUI previews can inject a mock with canned data.
/// 3. Future flexibility — could be backed by C-level libimobiledevice binding
///    instead of CLI subprocess calls, without changing the ViewModel layer.
///
/// **Concurrency model:**
/// - All methods are `async throws` for single-shot operations.
/// - Device polling uses `AsyncStream<DeviceEvent>` (long-lived, cancelable).
/// - Transfer progress uses `AsyncThrowingStream<TransferProgress, Error>` so
///   the stream can terminate with an error if the entire batch fails.
/// - Cancellation propagates through Swift structured concurrency: cancelling
///   the parent Task terminates the underlying Process via `Process.terminate()`.
///
/// **Sendable conformance:**
/// Required by Swift 6 strict concurrency. Implementations should be either
/// `actor` or `final class: @unchecked Sendable` with internal synchronization.
///
/// **Error handling:**
/// All methods throw `iMobileDeviceError`. The protocol does not use Result
/// or optional returns — callers use do/catch at the ViewModel layer.
protocol iMobileDeviceProtocol: Sendable {

    // MARK: Dependencies

    /// Checks whether all required CLI tools (idevice_id, ideviceinfo,
    /// ideviceinstaller) are installed and accessible.
    ///
    /// Fast operation — resolves tool paths via `which` or known Homebrew
    /// directories (/opt/homebrew/bin, /usr/local/bin).
    ///
    /// - Returns: `DependencyStatus` indicating readiness or missing tools.
    func checkDependencies() async -> DependencyStatus

    /// Opens Terminal.app and runs `brew install libimobiledevice ideviceinstaller`.
    ///
    /// This is a fire-and-forget action. The caller should poll
    /// `checkDependencies()` periodically (e.g. every 2s) to detect when
    /// installation completes.
    ///
    /// - Throws: `iMobileDeviceError.homebrewNotInstalled` if brew is not found.
    /// - Throws: `iMobileDeviceError.dependencyInstallFailed` if Terminal launch fails.
    func installDependencies() async throws

    // MARK: Device Discovery

    /// Lists all currently connected iOS devices.
    ///
    /// Runs `idevice_id -l` to get UDIDs, then `ideviceinfo -u <UDID>` for
    /// each device to populate full DeviceInfo.
    ///
    /// Typical latency: 200-500ms for a single device.
    ///
    /// - Returns: Array of connected devices. Empty array if none connected.
    /// - Throws: `iMobileDeviceError.dependencyMissing` if tools not installed.
    /// - Throws: `iMobileDeviceError.processExitedWithError` on CLI failure.
    func listDevices() async throws -> [DeviceInfo]

    /// Returns detailed info for a specific device by UDID.
    ///
    /// Runs `ideviceinfo -u <UDID>` and parses the key-value output.
    ///
    /// - Parameter udid: The target device UDID.
    /// - Returns: Populated DeviceInfo.
    /// - Throws: `iMobileDeviceError.deviceNotFound` if UDID is not connected.
    /// - Throws: `iMobileDeviceError.deviceNotTrusted` if device is locked/untrusted.
    func getDeviceInfo(udid: String) async throws -> DeviceInfo

    /// Emits device connect/disconnect events by polling `idevice_id -l`.
    ///
    /// **Why AsyncStream (not AsyncThrowingStream)?**
    /// Device polling is a long-lived background activity. Transient errors
    /// (e.g. USB glitch) should not terminate the stream. Errors are emitted
    /// as `DeviceEvent.error` and polling continues.
    ///
    /// **Polling interval:** 2 seconds (matches spec). Configurable via parameter.
    ///
    /// **Cancellation:** Dropping the stream or cancelling the consuming Task
    /// stops polling. The implementation should check `Task.isCancelled` between
    /// polls and terminate the underlying `Process` if one is running.
    ///
    /// **Why not AsyncStream<[DeviceInfo]>?**
    /// Event-based semantics (connected/disconnected) are more informative than
    /// diffing arrays. The ViewModel can maintain its own `Set<DeviceInfo>` and
    /// react to individual events for animations and state transitions.
    ///
    /// - Parameter pollingInterval: Seconds between polls. Default 2.0.
    /// - Returns: A never-throwing stream of device events.
    func observeDevices(pollingInterval: TimeInterval) -> AsyncStream<DeviceEvent>

    // MARK: App Management

    /// Lists user-installed applications on the device.
    ///
    /// Runs `ideviceinstaller -u <UDID> -l -o xml` and parses the plist output
    /// using `PropertyListDecoder` (preferred) or `PropertyListSerialization`
    /// for the array-of-dictionaries format.
    ///
    /// **Parsing strategy:**
    /// The `-o xml` flag produces Apple XML plist. The output is an array of
    /// dictionaries. Each dictionary is parsed into `AppInfo`.
    ///
    /// Recommended approach:
    /// ```swift
    /// let data = pipe.fileHandleForReading.readDataToEndOfFile()
    /// // PropertyListSerialization for untyped plist arrays:
    /// let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
    /// guard let apps = plist as? [[String: Any]] else { throw ... }
    /// ```
    ///
    /// **Why not PropertyListDecoder?**
    /// `PropertyListDecoder` requires the top-level type to be Codable. The
    /// ideviceinstaller output is an array of heterogeneous dictionaries with
    /// varying keys per app. `PropertyListSerialization` + manual mapping is
    /// more resilient to schema variations across libimobiledevice versions.
    ///
    /// **Filtering:** Returns only user apps by default. System apps
    /// (com.apple.*) are excluded. Caller can override via `includeSystem`.
    ///
    /// - Parameters:
    ///   - udid: Target device UDID.
    ///   - includeSystem: If true, includes Apple system apps. Default false.
    /// - Returns: Array of installed apps sorted by displayName.
    /// - Throws: `iMobileDeviceError.deviceNotFound` / `.appListParseFailed`.
    func listApps(udid: String, includeSystem: Bool) async throws -> [AppInfo]

    // MARK: IPA Extraction

    /// Extracts an .ipa file from the device to the local file system.
    ///
    /// **Primary method:** `ideviceinstaller -u <UDID> --extract <bundleID> --output <dir>`
    ///
    /// **Fallback (if --extract unsupported):**
    /// 1. Mount app container via `ifuse --container <bundleID> <mountpoint>`
    /// 2. Copy .app bundle from the mounted filesystem
    /// 3. Wrap in Payload/ directory and zip as .ipa
    /// 4. Unmount via `fusermount -u <mountpoint>` or `umount <mountpoint>`
    ///
    /// **Progress reporting:**
    /// `ideviceinstaller --extract` writes progress lines to stdout like:
    /// ```
    /// Copying 'com.example.app'...
    /// - 25% complete
    /// - 50% complete
    /// ...
    /// ```
    /// The implementation should read stdout line-by-line (not readDataToEndOfFile)
    /// using `FileHandle.AsyncBytes` or a readability source on the pipe, parse
    /// percentage values, and update the provided `progressHandler`.
    ///
    /// **Cancellation:**
    /// Dropping the Task cancels the extraction. The implementation must call
    /// `Process.terminate()` followed by `Process.waitUntilExit()` to ensure
    /// the subprocess is cleaned up. Partial .ipa files in `destinationDir`
    /// should be deleted on cancellation.
    ///
    /// - Parameters:
    ///   - udid: Source device UDID.
    ///   - bundleID: Bundle identifier of the app to extract.
    ///   - destinationDir: Local directory to write the .ipa into.
    ///   - progressHandler: Called with 0.0...1.0 as extraction progresses.
    ///                      Called on an unspecified queue; ViewModel must
    ///                      dispatch to @MainActor if updating UI state.
    /// - Returns: URL of the extracted .ipa file.
    /// - Throws: `iMobileDeviceError.extractionFailed`, `.extractionNotSupported`,
    ///           `.deviceDisconnected`, `.cancelled`.
    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL

    /// Installs an .ipa file onto the device.
    ///
    /// Runs `ideviceinstaller -u <UDID> -i <path.ipa>`.
    ///
    /// **Progress reporting:**
    /// `ideviceinstaller -i` writes progress lines to stdout:
    /// ```
    /// Copying 'app.ipa' to device...
    /// Installing 'com.example.app'
    ///  - 25% complete
    ///  - 50% complete
    ///  - Complete
    /// ```
    /// Same stdout line-by-line parsing strategy as `extractIPA`.
    ///
    /// **FairPlay / DRM consideration:**
    /// If the destination device uses a different Apple ID than the source,
    /// installation will fail with an error from ideviceinstaller. The
    /// implementation surfaces this as `iMobileDeviceError.installFailed`
    /// with the reason string from stderr. The UI layer is responsible for
    /// showing the Apple ID warning.
    ///
    /// - Parameters:
    ///   - udid: Destination device UDID.
    ///   - ipaPath: Local path to the .ipa file.
    ///   - progressHandler: Called with 0.0...1.0 as installation progresses.
    /// - Throws: `iMobileDeviceError.installFailed`, `.ipaFileNotFound`,
    ///           `.deviceDisconnected`, `.cancelled`.
    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws

    // MARK: Batch Transfer

    /// Transfers multiple apps from source device to destination device.
    ///
    /// This is the high-level orchestration method that drives the Step 4 UI.
    /// For each app in `apps`:
    /// 1. Extract .ipa from source device → temp directory
    /// 2. (Optional) Archive .ipa to `archiveDir` if non-nil
    /// 3. Install .ipa on destination device
    /// 4. Clean up temp file
    ///
    /// **Why AsyncThrowingStream (not AsyncStream)?**
    /// Unlike device polling, a batch transfer has a clear lifecycle: it either
    /// completes or fails fatally (e.g. source device disconnected permanently).
    /// Individual app failures are reported via `TransferProgress.failedApps`
    /// and do NOT throw — the stream continues to the next app. Only
    /// unrecoverable errors (both devices gone, cancellation) terminate the
    /// stream with a thrown error.
    ///
    /// **Sequential processing:**
    /// Apps are processed one at a time (extract -> install -> next).
    /// Parallel extraction would risk overwhelming USB bandwidth and the
    /// device's CPU. The `currentApp` / `currentPhase` fields in
    /// `TransferProgress` reflect this sequential model.
    ///
    /// **Cancellation:**
    /// Cancelling the consuming Task cancels the current extraction/installation
    /// Process and terminates the stream. Partial work (temp files) is cleaned up.
    /// Already-archived .ipa files are NOT deleted on cancellation (they are
    /// valuable to the user).
    ///
    /// - Parameters:
    ///   - sourceUDID: UDID of the device to extract apps from.
    ///   - destinationUDID: UDID of the device to install apps onto.
    ///   - apps: Apps to transfer, in the order they should be processed.
    ///   - archiveDir: If non-nil, each extracted .ipa is also copied here
    ///                 in the structure `<archiveDir>/<bundleID>/<version>/<name>.ipa`.
    /// - Returns: A throwing stream of transfer progress events, finishing with
    ///            the final `TransferProgress` where `isFinished == true`.
    func transferApps(
        sourceUDID: String,
        destinationUDID: String,
        apps: [AppInfo],
        archiveDir: URL?
    ) -> AsyncThrowingStream<TransferProgress, Error>
}

// MARK: - 5. Default Parameter Extension

/// Provides default parameter values for protocol methods.
///
/// Swift protocols cannot have default parameter values directly.
/// This extension pattern allows callers to omit optional parameters
/// while keeping the protocol definition explicit.
extension iMobileDeviceProtocol {

    func observeDevices() -> AsyncStream<DeviceEvent> {
        observeDevices(pollingInterval: 2.0)
    }

    func listApps(udid: String) async throws -> [AppInfo] {
        try await listApps(udid: udid, includeSystem: false)
    }
}

// MARK: - 6. Archive Protocol

/// Manages the local .ipa archive (library of saved apps).
///
/// Separated from iMobileDeviceProtocol because archive operations are
/// purely local filesystem work — no device communication needed.
/// This enables independent testing and a dedicated ArchiveViewModel.
protocol AppArchiveProtocol: Sendable {

    /// The root directory of the archive.
    var archiveDirectory: URL { get }

    /// Lists all archived apps, reading metadata.json from each bundle directory.
    ///
    /// Directory structure: `<archiveDir>/<bundleID>/<version>/`
    /// Each version directory contains: `<name>.ipa` + `metadata.json`.
    ///
    /// - Returns: Array of archived app metadata, sorted by archiveDate descending.
    func listArchivedApps() async throws -> [ArchivedApp]

    /// Saves an .ipa file to the archive with associated metadata.
    ///
    /// Creates the directory structure if it doesn't exist. If an .ipa with
    /// the same bundleID and version already exists, the `overwrite` parameter
    /// controls behavior.
    ///
    /// - Parameters:
    ///   - ipaPath: Path to the .ipa file to archive.
    ///   - metadata: App metadata to save alongside the .ipa.
    ///   - overwrite: If true, replaces existing archive. If false, throws
    ///                `iMobileDeviceError.archiveWriteFailed` if already exists.
    /// - Returns: URL of the archived .ipa file.
    func archiveIPA(
        ipaPath: URL,
        metadata: ArchivedAppMetadata,
        overwrite: Bool
    ) async throws -> URL

    /// Deletes an archived app (all versions or a specific version).
    ///
    /// - Parameters:
    ///   - bundleID: Bundle identifier to delete.
    ///   - version: If nil, deletes all versions. If specified, only that version.
    func deleteArchive(bundleID: String, version: String?) async throws

    /// Returns the total size of the archive directory in bytes.
    func totalArchiveSize() async throws -> UInt64
}

// MARK: ArchivedApp

/// Represents a single app entry in the local archive.
struct ArchivedApp: Identifiable, Sendable {
    let bundleID: String
    let displayName: String
    let version: String
    let ipaSize: UInt64
    let archiveDate: Date
    let sourceDevice: String
    let ipaPath: URL
    /// Base64-encoded icon data (60x60 PNG). Nil if icon unavailable.
    let iconData: Data?

    var id: String { "\(bundleID)/\(version)" }
}

// MARK: ArchivedAppMetadata

/// Metadata written to `metadata.json` alongside each archived .ipa.
///
/// Codable for JSON serialization. Matches the structure defined in the spec.
struct ArchivedAppMetadata: Codable, Sendable {
    let bundleID: String
    let displayName: String
    let version: String
    let ipaSize: UInt64
    let archivedAt: Date
    let sourceDevice: String
    /// Base64-encoded icon PNG data.
    let iconData: String?
}

// MARK: - 7. Mock Implementation (API Shape Only)

/// Mock implementation of `iMobileDeviceProtocol` for testing and SwiftUI previews.
///
/// ## Usage in Tests
/// ```swift
/// let mock = MockiMobileDeviceService()
/// mock.devicesToReturn = [DeviceInfo(...)]
/// mock.appsToReturn = [AppInfo(...)]
/// let vm = iTransferViewModel(service: mock)
/// await vm.connectSourceDevice()
/// XCTAssertEqual(vm.sourceDevice?.udid, "mock-udid")
/// ```
///
/// ## Usage in SwiftUI Previews
/// ```swift
/// #Preview {
///     AppListView(viewModel: iTransferViewModel(
///         service: MockiMobileDeviceService.withSampleData()
///     ))
/// }
/// ```
///
/// ## Configurable Behaviors
/// - `devicesToReturn` — controls `listDevices()` / `getDeviceInfo()` output
/// - `appsToReturn` — controls `listApps()` output
/// - `errorToThrow` — if set, all methods throw this error
/// - `extractionDelay` — simulates slow extraction for progress testing
/// - `installationShouldFail` — simulates install failure for DRM testing
/// - `deviceEventSequence` — predetermined events for `observeDevices()`
final class MockiMobileDeviceService: iMobileDeviceProtocol, @unchecked Sendable {

    // Configurable behavior
    var dependencyStatus: DependencyStatus = .ready(ToolPaths(
        ideviceId: "/opt/homebrew/bin/idevice_id",
        ideviceInfo: "/opt/homebrew/bin/ideviceinfo",
        ideviceInstaller: "/opt/homebrew/bin/ideviceinstaller",
        ifuse: nil
    ))
    var devicesToReturn: [DeviceInfo] = []
    var appsToReturn: [AppInfo] = []
    var errorToThrow: iMobileDeviceError?
    var extractionDelay: TimeInterval = 0.5
    var installationShouldFail: Set<String> = [] // bundleIDs that fail install
    var deviceEventSequence: [DeviceEvent] = []

    // Call tracking for assertions
    var listDevicesCallCount = 0
    var listAppsCallCount = 0
    var extractIPACallCount = 0
    var installIPACallCount = 0

    func checkDependencies() async -> DependencyStatus {
        dependencyStatus
    }

    func installDependencies() async throws {
        if let error = errorToThrow { throw error }
    }

    func listDevices() async throws -> [DeviceInfo] {
        listDevicesCallCount += 1
        if let error = errorToThrow { throw error }
        return devicesToReturn
    }

    func getDeviceInfo(udid: String) async throws -> DeviceInfo {
        if let error = errorToThrow { throw error }
        guard let device = devicesToReturn.first(where: { $0.udid == udid }) else {
            throw iMobileDeviceError.deviceNotFound(udid: udid)
        }
        return device
    }

    func observeDevices(pollingInterval: TimeInterval) -> AsyncStream<DeviceEvent> {
        let events = deviceEventSequence
        return AsyncStream { continuation in
            Task {
                for event in events {
                    try? await Task.sleep(for: .seconds(pollingInterval))
                    guard !Task.isCancelled else { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    func listApps(udid: String, includeSystem: Bool) async throws -> [AppInfo] {
        listAppsCallCount += 1
        if let error = errorToThrow { throw error }
        return appsToReturn
    }

    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        extractIPACallCount += 1
        if let error = errorToThrow { throw error }
        // Simulate progress
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            try? await Task.sleep(for: .seconds(extractionDelay / 4))
            guard !Task.isCancelled else { throw iMobileDeviceError.cancelled }
            progressHandler(step)
        }
        let fakeIPA = destinationDir.appendingPathComponent("\(bundleID).ipa")
        // In a real mock: create an empty file for integration tests
        return fakeIPA
    }

    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws {
        installIPACallCount += 1
        if let error = errorToThrow { throw error }
        let bundleID = ipaPath.deletingPathExtension().lastPathComponent
        if installationShouldFail.contains(bundleID) {
            throw iMobileDeviceError.installFailed(
                bundleID: bundleID,
                reason: "FairPlay verification failed — Apple ID mismatch"
            )
        }
        for step in stride(from: 0.0, through: 1.0, by: 0.25) {
            try? await Task.sleep(for: .seconds(extractionDelay / 4))
            guard !Task.isCancelled else { throw iMobileDeviceError.cancelled }
            progressHandler(step)
        }
    }

    func transferApps(
        sourceUDID: String,
        destinationUDID: String,
        apps: [AppInfo],
        archiveDir: URL?
    ) -> AsyncThrowingStream<TransferProgress, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                var completed = 0
                var failed = 0
                for app in apps {
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: iMobileDeviceError.cancelled)
                        return
                    }
                    // Simulate extraction + installation
                    try? await Task.sleep(for: .seconds(self.extractionDelay))
                    if self.installationShouldFail.contains(app.bundleID) {
                        failed += 1
                    } else {
                        completed += 1
                    }
                    continuation.yield(TransferProgress(
                        totalApps: apps.count,
                        completedApps: completed + failed,
                        failedApps: failed,
                        currentApp: app,
                        currentPhase: .completed,
                        currentAppProgress: 1.0,
                        bytesTransferred: app.staticDiskUsage * UInt64(completed),
                        bytesTotal: apps.reduce(0) { $0 + $1.staticDiskUsage }
                    ))
                }
                continuation.finish()
            }
        }
    }

    /// Factory for SwiftUI previews with realistic sample data.
    static func withSampleData() -> MockiMobileDeviceService {
        let mock = MockiMobileDeviceService()
        mock.devicesToReturn = [
            DeviceInfo(
                udid: "00008030-001A2B3C4D5E6F70",
                deviceName: "iPhone Artyom",
                productType: "iPhone16,1",
                productVersion: "18.3.1",
                deviceClass: "iPhone"
            )
        ]
        mock.appsToReturn = [
            AppInfo(
                bundleID: "com.sberbank.online",
                displayName: "SberBank",
                version: "15.3.1",
                buildNumber: "2024031901",
                staticDiskUsage: 50_331_648,
                dynamicDiskUsage: 104_857_600,
                signerIdentity: "Apple iPhone OS Application Signing"
            ),
            AppInfo(
                bundleID: "com.tinkoff.bank",
                displayName: "Tinkoff",
                version: "6.12.0",
                buildNumber: nil,
                staticDiskUsage: 54_525_952,
                dynamicDiskUsage: 83_886_080,
                signerIdentity: "Apple iPhone OS Application Signing"
            ),
        ]
        return mock
    }
}

// MARK: - 8. ViewModel Integration Notes (Not Code — Design Guidance)

// The following is NOT executable code. It documents how the protocol
// integrates with the ViewModel layer, preserving Spacie's MVVM pattern.

/*

 ## iTransferViewModel Integration

 ```swift
 @Observable
 final class iTransferViewModel {
     // --- State Machine ---
     // Follows the Wizard steps from the spec:
     enum Step: Sendable {
         case dependencyCheck
         case connectSource
         case selectApps
         case connectDestination
         case transferring
         case result
     }

     var currentStep: Step = .dependencyCheck
     var dependencyStatus: DependencyStatus?
     var sourceDevice: DeviceInfo?
     var destinationDevice: DeviceInfo?
     var availableApps: [AppInfo] = []
     var selectedAppIDs: Set<String> = []
     var transferItems: [TransferItem] = []
     var transferResult: TransferResult?
     var error: iMobileDeviceError?
     var isLoading: Bool = false

     // --- Dependency Injection ---
     private let service: any iMobileDeviceProtocol
     private let archive: any AppArchiveProtocol

     init(service: any iMobileDeviceProtocol, archive: any AppArchiveProtocol) {
         self.service = service
         self.archive = archive
     }

     // --- Device Observation ---
     // The ViewModel starts observing when entering connectSource/connectDestination.
     // It stores the Task handle and cancels it when leaving the step.
     private var deviceObservationTask: Task<Void, Never>?

     func startDeviceObservation() {
         deviceObservationTask = Task {
             for await event in service.observeDevices() {
                 // Handle on @MainActor via Task { @MainActor in ... }
             }
         }
     }

     func stopDeviceObservation() {
         deviceObservationTask?.cancel()
         deviceObservationTask = nil
     }

     // --- Transfer ---
     // Uses the AsyncThrowingStream from transferApps().
     // Stores the consuming Task for cancellation support.
     private var transferTask: Task<Void, Never>?

     func startTransfer() {
         guard let source = sourceDevice, let dest = destinationDevice else { return }
         let selectedApps = availableApps.filter { selectedAppIDs.contains($0.bundleID) }
         let archiveDir = shouldArchive ? archive.archiveDirectory : nil

         transferTask = Task {
             do {
                 for try await progress in service.transferApps(
                     sourceUDID: source.udid,
                     destinationUDID: dest.udid,
                     apps: selectedApps,
                     archiveDir: archiveDir
                 ) {
                     // Update transferItems from progress
                 }
                 currentStep = .result
             } catch {
                 self.error = error as? iMobileDeviceError
             }
         }
     }

     func cancelTransfer() {
         transferTask?.cancel()
         transferTask = nil
     }
 }
 ```

 ## Cancellation Architecture

 Three levels of cancellation, all leveraging Swift structured concurrency:

 1. **Individual Process**: `Process.terminate()` kills the CLI subprocess.
    Called from `withTaskCancellationHandler` in the Process wrapper.

 2. **Single Operation**: Cancelling the Task that called `extractIPA` or
    `installIPA` triggers the process termination + cleanup.

 3. **Entire Transfer**: Cancelling the `transferTask` in the ViewModel
    propagates through the AsyncThrowingStream, terminating the current
    operation and cleaning up temp files.

 Implementation pattern for Process wrapper:

 ```swift
 private func runProcess(_ executable: String, arguments: [String]) async throws -> Data {
     let process = Process()
     process.executableURL = URL(fileURLWithPath: executable)
     process.arguments = arguments
     let stdoutPipe = Pipe()
     let stderrPipe = Pipe()
     process.standardOutput = stdoutPipe
     process.standardError = stderrPipe

     return try await withTaskCancellationHandler {
         try await withCheckedThrowingContinuation { continuation in
             process.terminationHandler = { proc in
                 let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                 let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                 if proc.terminationStatus == 0 {
                     continuation.resume(returning: stdout)
                 } else {
                     let errMsg = String(data: stderr, encoding: .utf8) ?? ""
                     continuation.resume(throwing: iMobileDeviceError.processExitedWithError(
                         tool: executable, exitCode: proc.terminationStatus, stderr: errMsg
                     ))
                 }
             }
             do { try process.run() }
             catch { continuation.resume(throwing: error) }
         }
     } onCancel: {
         process.terminate()
     }
 }
 ```

 ## Progress Parsing Strategy

 For `extractIPA` and `installIPA`, stdout is read line-by-line to parse
 progress percentages. Two approaches depending on available APIs:

 **Option A: FileHandle.AsyncBytes (preferred, macOS 12+)**
 ```swift
 let pipe = Pipe()
 process.standardOutput = pipe
 try process.run()

 for try await line in pipe.fileHandleForReading.bytes.lines {
     if let percent = parseProgressLine(line) {
         progressHandler(percent / 100.0)
     }
 }
 ```

 **Option B: DispatchSource for readability**
 ```swift
 let source = DispatchSource.makeReadSource(
     fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
     queue: .global(qos: .userInitiated)
 )
 source.setEventHandler { /* read available bytes, buffer, split lines */ }
 source.resume()
 ```

 Option A is simpler and aligns with Swift concurrency. Use it.

 ## Plist Parsing

 For `ideviceinstaller -u <UDID> -l -o xml`:

 ```swift
 let data = pipe.fileHandleForReading.readDataToEndOfFile()
 guard let plist = try PropertyListSerialization.propertyList(
     from: data, options: [], format: nil
 ) as? [[String: Any]] else {
     throw iMobileDeviceError.appListParseFailed(
         reason: "Expected array of dictionaries",
         rawOutput: String(data: data.prefix(500), encoding: .utf8)
     )
 }

 let apps = plist.compactMap { dict -> AppInfo? in
     guard let bundleID = dict["CFBundleIdentifier"] as? String else { return nil }
     return AppInfo(
         bundleID: bundleID,
         displayName: (dict["CFBundleDisplayName"] as? String)
                   ?? (dict["CFBundleName"] as? String)
                   ?? bundleID,
         version: (dict["CFBundleShortVersionString"] as? String) ?? "?",
         buildNumber: dict["CFBundleVersion"] as? String,
         staticDiskUsage: (dict["StaticDiskUsage"] as? UInt64) ?? 0,
         dynamicDiskUsage: (dict["DynamicDiskUsage"] as? UInt64) ?? 0,
         signerIdentity: dict["SignerIdentity"] as? String
     )
 }
 ```

 */
