import Foundation

// MARK: - iMobileDeviceProtocol

/// Abstraction over `libimobiledevice` CLI tools for discovering, querying,
/// and transferring apps between iOS devices and the Mac.
///
/// All methods are asynchronous and designed for structured concurrency.
/// Implementations must be `Sendable` so they can be shared across isolation
/// domains (e.g. injected into a `@MainActor`-isolated view model).
///
/// ## Dependency Lifecycle
///
/// Before calling any device or app methods, consumers should verify that all
/// required CLI tools are present via ``checkDependencies()``. If tools are
/// missing, ``installDependencies(onLine:)`` runs `brew install` as a child
/// process (not through Terminal.app) and streams Homebrew's output for
/// progress display.
///
/// ## Thread Safety
///
/// The protocol requires `Sendable` conformance. The canonical implementation
/// (``iMobileDeviceService``) is an `actor`, so all mutable state is protected
/// by actor isolation.
///
/// ## Security
///
/// All UDID and bundle-ID parameters are validated through ``InputValidator``
/// before being passed to external processes. Display names are sanitised to
/// strip control characters and bidi overrides.
protocol iMobileDeviceProtocol: Sendable {

    // MARK: - Dependencies

    /// Checks whether Homebrew and the required `libimobiledevice` CLI tools
    /// are installed on this machine.
    ///
    /// - Returns: ``DependencyStatus/ready(_:)`` when all tools are found,
    ///   ``DependencyStatus/missing(tools:)`` when Homebrew is present but
    ///   some tools are absent, or ``DependencyStatus/homebrewMissing`` when
    ///   Homebrew itself cannot be located.
    func checkDependencies() async -> DependencyStatus

    /// Installs the required `libimobiledevice` and `ideviceinstaller`
    /// packages via Homebrew.
    ///
    /// The install is run as a child process (not through Terminal.app).
    /// Each line of Homebrew's stdout is forwarded to the caller through
    /// `onLine` so the UI can display real-time progress.
    ///
    /// After a successful install the internal tool-path cache is invalidated
    /// so that subsequent ``checkDependencies()`` calls pick up the new paths.
    ///
    /// - Parameter onLine: Closure invoked for each line of Homebrew output.
    ///   Called on a background thread; callers must dispatch to `@MainActor`
    ///   if they update UI state.
    /// - Throws: ``iMobileDeviceError/dependencyInstallFailed(reason:)`` if
    ///   `brew install` exits with a non-zero status.
    func installDependencies(
        onLine: @escaping @Sendable (String) -> Void
    ) async throws

    // MARK: - Apple ID Authentication

    /// Checks whether ipatool is currently authenticated with an Apple ID.
    ///
    /// Runs `ipatool auth info` and returns `true` if the process exits with
    /// code 0 (indicating a valid, unexpired session).
    ///
    /// - Returns: `true` if ipatool has a valid authenticated session.
    func checkAppleIDAuth() async -> Bool

    /// Authenticates ipatool with the given Apple ID credentials.
    ///
    /// Runs `ipatool auth login --email <email> --password <password>` and
    /// optionally appends `--auth-code <code>` when a 2FA code is provided.
    ///
    /// - Parameters:
    ///   - email: The Apple ID email address.
    ///   - password: The Apple ID password.
    ///   - authCode: Optional 6-digit two-factor authentication code. Pass
    ///     `nil` or an empty string to omit.
    /// - Throws: ``iMobileDeviceError/authFailed(reason:)`` if `ipatool auth login`
    ///   exits with a non-zero status.
    func loginAppleID(email: String, password: String, authCode: String?) async throws

    // MARK: - Device Discovery

    /// Lists all currently connected iOS devices.
    ///
    /// Runs `idevice_id -l` to enumerate UDIDs, then queries `ideviceinfo`
    /// for each device to populate ``DeviceInfo`` metadata.
    ///
    /// - Returns: An array of connected devices. Empty if none are connected.
    /// - Throws: ``iMobileDeviceError/processExitedWithError(tool:exitCode:stderr:)``
    ///   if a CLI tool fails, or ``iMobileDeviceError/dependencyMissing(_:)``
    ///   if tools have not been resolved.
    func listDevices() async throws -> [DeviceInfo]

    /// Returns an `AsyncStream` that emits ``DeviceEvent`` values whenever
    /// the set of connected devices changes.
    ///
    /// The stream polls ``listDevices()`` at the specified interval and diffs
    /// against the previously known set of UDIDs. It emits
    /// ``DeviceEvent/connected(_:)`` for new devices and
    /// ``DeviceEvent/disconnected(udid:)`` for removed ones.
    ///
    /// The stream terminates when the enclosing `Task` is cancelled.
    ///
    /// - Parameter pollingInterval: Seconds between successive polls.
    ///   Values below 1.0 are clamped to 1.0 to avoid excessive CPU usage.
    /// - Returns: An infinite stream of device events.
    func observeDevices(
        pollingInterval: TimeInterval
    ) -> AsyncStream<DeviceEvent>

    // MARK: - Trust

    /// Determines the trust relationship between this Mac and the specified
    /// iOS device.
    ///
    /// Performs a three-level check:
    /// 1. Verifies the UDID appears in `idevice_id -l` (device is connected).
    /// 2. Runs `idevicepair validate -u <udid>` to check pairing status.
    /// 3. Confirms the pairing by issuing a quick `ideviceinfo` query.
    ///
    /// - Parameter udid: The validated device UDID.
    /// - Returns: The current ``TrustState`` for the device.
    func validateTrust(udid: String) async -> TrustState

    // MARK: - App Management

    /// Lists all user-installed applications on the specified device.
    ///
    /// System apps are excluded. The returned ``AppInfo`` values contain
    /// validated bundle identifiers and sanitised display names.
    ///
    /// - Parameter udid: The validated UDID of the target device.
    /// - Returns: An array of user-installed apps.
    /// - Throws: ``iMobileDeviceError/appListParseFailed(reason:rawOutput:)``
    ///   if the plist output cannot be parsed,
    ///   ``iMobileDeviceError/deviceNotFound(udid:)`` if the device is not
    ///   connected.
    func listApps(udid: String) async throws -> [AppInfo]

    // MARK: - IPA Extraction

    /// Extracts (archives) a single app from the device as an IPA file.
    ///
    /// Uses `ideviceinstaller -u <udid> -a <bundleID>` to pull the app
    /// binary. Progress is reported through `progressHandler` as a fraction
    /// from 0.0 to 1.0, parsed from the tool's stdout.
    ///
    /// - Parameters:
    ///   - udid: The validated UDID of the source device.
    ///   - bundleID: The validated bundle identifier of the app to extract.
    ///   - destinationDir: Directory where the `.ipa` file will be written.
    ///     Must already exist on disk.
    ///   - progressHandler: Closure invoked with fractional progress (0.0...1.0).
    ///     Called on a background thread.
    /// - Returns: The file URL of the extracted `.ipa`.
    /// - Throws: ``iMobileDeviceError/extractionFailed(bundleID:reason:)`` on
    ///   failure, ``iMobileDeviceError/processExitedWithError(tool:exitCode:stderr:)``
    ///   if the tool exits with non-zero status.
    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    // MARK: - IPA Installation

    /// Installs an IPA file onto the specified device.
    ///
    /// Uses `ideviceinstaller -u <udid> -i <ipaPath>`. Progress is reported
    /// through `progressHandler` as a fraction from 0.0 to 1.0.
    ///
    /// - Parameters:
    ///   - udid: The validated UDID of the target device.
    ///   - ipaPath: File URL pointing to the `.ipa` to install. Must exist.
    ///   - progressHandler: Closure invoked with fractional progress (0.0...1.0).
    ///     Called on a background thread.
    /// - Throws: ``iMobileDeviceError/installFailed(bundleID:reason:)`` on
    ///   failure, ``iMobileDeviceError/ipaFileNotFound(path:)`` if `ipaPath`
    ///   does not exist.
    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws

    // MARK: - Batch Transfer

    /// Transfers multiple apps from a source device, optionally archiving
    /// and/or installing them on a destination device.
    ///
    /// Apps are processed sequentially. For each app the stream yields
    /// a ``TransferProgress`` snapshot reflecting the current state of all
    /// items in the batch.
    ///
    /// The transfer performs up to three steps per app:
    /// 1. **Extract** the IPA from the source device.
    /// 2. **Archive** (copy) the IPA to `archiveDir` if provided.
    /// 3. **Install** the IPA on `destinationUDID` if `shouldInstall` is
    ///    `true` and a destination device is connected.
    ///
    /// The stream finishes normally after the last app is processed, or
    /// throws if an unrecoverable error occurs. Per-app failures are recorded
    /// in ``TransferItem/error`` and do not terminate the stream.
    ///
    /// - Parameters:
    ///   - sourceUDID: The validated UDID of the device to extract apps from.
    ///   - destinationUDID: The validated UDID of the device to install onto,
    ///     or `nil` for archive-only mode.
    ///   - apps: The list of apps to transfer.
    ///   - archiveDir: Directory to copy extracted IPAs into. `nil` to skip
    ///     archiving.
    ///   - shouldInstall: Whether to install each extracted IPA on the
    ///     destination device.
    /// - Returns: An `AsyncThrowingStream` of ``TransferProgress`` snapshots.
    func transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: [AppInfo],
        archiveDir: URL?,
        shouldInstall: Bool
    ) -> AsyncThrowingStream<TransferProgress, Error>
}
