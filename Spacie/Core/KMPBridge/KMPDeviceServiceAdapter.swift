import Foundation
import SpacieKit

// MARK: - KMPDeviceServiceAdapter

/// Swift adapter that bridges the KMP `SpaDeviceServiceApi` protocol to the
/// Swift-native `iMobileDeviceProtocol`.
///
/// The adapter is an `actor` to satisfy Swift 6 strict-concurrency requirements.
/// All KMP completion-handler methods are wrapped in `withCheckedThrowingContinuation`
/// so callers can use `async/await` idiomatically.
///
/// ## Concurrency notes
/// - All actor-isolated methods may be called from any isolation domain.
/// - `observeDevices` and `transferApps` bridge KMP flows to Swift async sequences
///   using a polling/orchestration model to avoid ObjC type-erasure pitfalls.
/// - `KotlinBoolean` returned by `checkAppleIDAuth` is unwrapped via `boolValue`.
/// - `KotlinByteArray` is converted to `Data` by iterating byte-by-byte.
actor KMPDeviceServiceAdapter: iMobileDeviceProtocol {

    // MARK: - KMP service

    private let kmpService: any SpaDeviceServiceApi = SpaSpacieFactory.shared.createDeviceService()

    // MARK: - checkDependencies

    func checkDependencies() async -> DependencyStatus {
        await withCheckedContinuation { continuation in
            kmpService.checkDependencies { kmpStatus, _ in
                guard let kmpStatus else {
                    continuation.resume(returning: .homebrewMissing)
                    return
                }
                continuation.resume(returning: kmpStatus.toSwift())
            }
        }
    }

    // MARK: - installDependencies

    func installDependencies(onLine: @escaping @Sendable (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kmpService.installDependencies(onLine: { line in
                onLine(line)
            }) { error in
                if let error {
                    continuation.resume(throwing: mapKMPError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - checkAppleIDAuth

    func checkAppleIDAuth() async -> Bool {
        await withCheckedContinuation { continuation in
            kmpService.checkAppleIDAuth { kotlinBool, _ in
                continuation.resume(returning: kotlinBool?.boolValue ?? false)
            }
        }
    }

    // MARK: - loginAppleID

    func loginAppleID(email: String, password: String, authCode: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kmpService.loginAppleID(email: email, password: password, authCode: authCode) { error in
                if let error {
                    continuation.resume(throwing: mapKMPError(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - listDevices

    func listDevices() async throws -> [DeviceInfo] {
        try await withCheckedThrowingContinuation { continuation in
            kmpService.listDevices { kmpDevices, error in
                if let error {
                    continuation.resume(throwing: mapKMPError(error))
                    return
                }
                let devices = (kmpDevices ?? []).map { $0.toSwift() }
                continuation.resume(returning: devices)
            }
        }
    }

    // MARK: - observeDevices

    /// Polls `listDevices()` at the given interval and emits device lifecycle events.
    ///
    /// A pure-Swift polling loop is used instead of wrapping the KMP flow directly
    /// because KMP flows involve Kotlin coroutine dispatch that can deadlock when
    /// bridged naively into Swift concurrency.
    nonisolated func observeDevices(pollingInterval: TimeInterval) -> AsyncStream<DeviceEvent> {
        let clampedInterval = max(pollingInterval, 1.0)
        return AsyncStream { continuation in
            let task = Task {
                var knownUDIDs = Set<String>()
                var knownTrustStates: [String: TrustState] = [:]

                while !Task.isCancelled {
                    let devices: [DeviceInfo]
                    do {
                        devices = try await self.listDevices()
                    } catch {
                        continuation.yield(.error(error))
                        try? await Task.sleep(nanoseconds: UInt64(clampedInterval * 1_000_000_000))
                        continue
                    }

                    let currentUDIDs = Set(devices.map(\.udid))

                    // Emit connected events for newly appeared devices.
                    for device in devices where !knownUDIDs.contains(device.udid) {
                        knownUDIDs.insert(device.udid)
                        continuation.yield(.connected(device))
                    }

                    // Emit disconnected events for devices that disappeared.
                    for udid in knownUDIDs where !currentUDIDs.contains(udid) {
                        knownUDIDs.remove(udid)
                        knownTrustStates.removeValue(forKey: udid)
                        continuation.yield(.disconnected(udid: udid))
                    }

                    // Poll trust state for connected devices and emit changes.
                    for device in devices {
                        let newState = await self.validateTrust(udid: device.udid)
                        let oldState = knownTrustStates[device.udid]
                        if oldState != newState {
                            knownTrustStates[device.udid] = newState
                            if oldState != nil {
                                // Only emit trustStateChanged for actual transitions,
                                // not on the first observation of a device.
                                continuation.yield(.trustStateChanged(udid: device.udid, state: newState))
                            }
                        }
                    }

                    try? await Task.sleep(nanoseconds: UInt64(clampedInterval * 1_000_000_000))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - validateTrust

    func validateTrust(udid: String) async -> TrustState {
        await withCheckedContinuation { continuation in
            kmpService.validateTrust(udid: udid) { kmpState, _ in
                continuation.resume(returning: (kmpState ?? SpaTrustState.notTrusted).toSwift())
            }
        }
    }

    // MARK: - listApps

    func listApps(udid: String) async throws -> [AppInfo] {
        try await withCheckedThrowingContinuation { continuation in
            kmpService.listApps(udid: udid) { kmpApps, error in
                if let error {
                    continuation.resume(throwing: mapKMPError(error))
                    return
                }
                let apps = (kmpApps ?? []).map { $0.toSwift() }
                continuation.resume(returning: apps)
            }
        }
    }

    // MARK: - extractIPA

    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let resultPath: String = try await withCheckedThrowingContinuation { continuation in
            kmpService.extractIPA(
                udid: udid,
                bundleID: bundleID,
                destinationDir: destinationDir.path,
                onProgress: { kotlinDouble in
                    progressHandler(kotlinDouble.doubleValue)
                },
                completionHandler: { path, error in
                    if let error {
                        continuation.resume(throwing: mapKMPError(error))
                        return
                    }
                    guard let path else {
                        continuation.resume(
                            throwing: iMobileDeviceError.extractionFailed(
                                bundleID: bundleID,
                                reason: "KMP returned nil path"
                            )
                        )
                        return
                    }
                    continuation.resume(returning: path)
                }
            )
        }
        return URL(fileURLWithPath: resultPath)
    }

    // MARK: - installIPA

    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kmpService.installIPA(
                udid: udid,
                ipaPath: ipaPath.path,
                onProgress: { kotlinDouble in
                    progressHandler(kotlinDouble.doubleValue)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: mapKMPError(error))
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    // MARK: - transferApps

    /// Orchestrates extraction, optional archiving, and optional installation
    /// for each app sequentially, yielding `TransferProgress` snapshots.
    ///
    /// Per-app failures are recorded in `TransferItem.error` and do not
    /// terminate the stream. Unrecoverable errors (e.g. cancelled task)
    /// finish the stream.
    nonisolated func transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: [AppInfo],
        archiveDir: URL?,
        shouldInstall: Bool
    ) -> AsyncThrowingStream<TransferProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var items = apps.map { TransferItem(id: $0.bundleID, app: $0) }
                let tempBase = FileManager.default.temporaryDirectory

                for i in items.indices {
                    if Task.isCancelled {
                        continuation.finish(throwing: iMobileDeviceError.cancelled)
                        return
                    }

                    let tempDir = tempBase.appendingPathComponent(UUID().uuidString)

                    defer {
                        try? FileManager.default.removeItem(at: tempDir)
                    }

                    try? FileManager.default.createDirectory(
                        at: tempDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )

                    // Phase: extracting
                    items[i].phase = .extracting
                    items[i].progress = 0.0
                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))

                    do {
                        let ipaURL = try await self.extractIPA(
                            udid: sourceUDID,
                            bundleID: items[i].app.bundleID,
                            destinationDir: tempDir,
                            progressHandler: { progress in
                                // Progress updates happen off-actor; items is a local copy.
                            }
                        )

                        // Phase: archiving (optional)
                        if let archiveDir {
                            items[i].phase = .archiving
                            continuation.yield(TransferProgress(items: items, currentItemIndex: i))

                            let destDir = archiveDir.appendingPathComponent(UUID().uuidString)
                            try FileManager.default.createDirectory(
                                at: destDir,
                                withIntermediateDirectories: true,
                                attributes: nil
                            )
                            let destIPA = destDir.appendingPathComponent(ipaURL.lastPathComponent)
                            do {
                                try FileManager.default.copyItem(at: ipaURL, to: destIPA)
                            } catch {
                                throw iMobileDeviceError.archiveWriteFailed(
                                    path: destIPA.path,
                                    reason: error.localizedDescription
                                )
                            }
                        }

                        // Phase: installing (optional)
                        if shouldInstall, let destUDID = destinationUDID {
                            items[i].phase = .installing
                            continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                            try await self.installIPA(
                                udid: destUDID,
                                ipaPath: ipaURL,
                                progressHandler: { _ in }
                            )
                        }

                        items[i].phase = .completed
                        items[i].progress = 1.0

                    } catch let deviceError as iMobileDeviceError {
                        items[i].phase = .failed
                        items[i].error = deviceError
                    } catch {
                        items[i].phase = .failed
                        items[i].error = .extractionFailed(
                            bundleID: items[i].app.bundleID,
                            reason: error.localizedDescription
                        )
                    }

                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - SpaDeviceInfo → DeviceInfo

private extension SpaDeviceInfo {

    func toSwift() -> DeviceInfo {
        DeviceInfo(
            udid: udid,
            deviceName: deviceName,
            productType: productType,
            productVersion: productVersion,
            buildVersion: buildVersion
        )
    }
}

// MARK: - SpaAppInfo → AppInfo

private extension SpaAppInfo {

    func toSwift() -> AppInfo {
        // Kotlin `Long?` is bridged as `KotlinLong?` (which is `NSNumber`-based).
        // Guard against negative values before converting to UInt64.
        let safeipaSize: UInt64?
        if let boxed = ipaSize {
            let raw = boxed.int64Value
            safeipaSize = raw >= 0 ? UInt64(raw) : nil
        } else {
            safeipaSize = nil
        }

        // Convert KotlinByteArray → Data by iterating individual bytes.
        let iconBytes: Data?
        if let ba = iconData {
            let count = Int(ba.size)
            var bytes = [UInt8](repeating: 0, count: count)
            for idx in 0 ..< count {
                bytes[idx] = UInt8(bitPattern: ba.get(index: Int32(idx)))
            }
            iconBytes = Data(bytes)
        } else {
            iconBytes = nil
        }

        return AppInfo(
            bundleID: bundleID,
            displayName: displayName,
            version: version,
            shortVersion: shortVersion,
            ipaSize: safeipaSize,
            iconData: iconBytes
        )
    }
}

// MARK: - SpaTrustState → TrustState

private extension SpaTrustState {

    func toSwift() -> TrustState {
        // SpaTrustState is a KotlinEnum; compare by identity to the singleton entries.
        if self === SpaTrustState.trusted {
            return .trusted
        } else if self === SpaTrustState.dialogShown {
            return .dialogShown
        } else {
            return .notTrusted
        }
    }
}

// MARK: - SpaDependencyStatus → DependencyStatus

private extension SpaDependencyStatus {

    func toSwift() -> DependencyStatus {
        if self is SpaDependencyStatus.SpaDependencyStatusHomebrewMissing {
            return .homebrewMissing
        }

        if let missing = self as? SpaDependencyStatus.SpaDependencyStatusMissing {
            return .missing(tools: missing.tools)
        }

        if let ready = self as? SpaDependencyStatus.SpaDependencyStatusReady {
            let paths = ready.toolPaths
            // Build ToolPaths from the dictionary; fall back to empty strings if a
            // key is unexpectedly absent (should not happen in practice).
            let toolPaths = ToolPaths(
                ideviceId: paths["idevice_id"] ?? "",
                ideviceInfo: paths["ideviceinfo"] ?? "",
                ideviceinstaller: paths["ideviceinstaller"] ?? "",
                idevicepair: paths["idevicepair"] ?? "",
                brew: paths["brew"] ?? "",
                ipatool: paths["ipatool"] ?? ""
            )
            return .ready(toolPaths)
        }

        // Fallback — should be unreachable with a correct KMP implementation.
        return .homebrewMissing
    }
}

// MARK: - Error mapping

/// Maps a raw `Error` (typically an `NSError` wrapping a `SpaSpacieError` subclass)
/// to the Swift-native `iMobileDeviceError`.
///
/// KMP `@Throws`-annotated suspend functions surface Kotlin exceptions as
/// `NSError` values. The original Kotlin object is accessible via the
/// `kotlinException` property injected by the KMP runtime on `NSError`.
private func mapKMPError(_ error: Error) -> iMobileDeviceError {
    let nsError = error as NSError

    // Prefer the strongly-typed Kotlin exception when available.
    let kotlinException = nsError.kotlinException ?? error

    if kotlinException is SpaSpacieError.SpaSpacieErrorHomebrewNotInstalled {
        return .homebrewNotInstalled
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDependencyMissing {
        return .dependencyMissing(e.tools)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDependencyInstallFailed {
        return .dependencyInstallFailed(reason: e.reason)
    }

    if kotlinException is SpaSpacieError.SpaSpacieErrorTwoFactorRequired {
        return .twoFactorRequired
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorAuthFailed {
        return .authFailed(reason: e.reason)
    }

    if kotlinException is SpaSpacieError.SpaSpacieErrorNotAuthenticated {
        return .notAuthenticated
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceNotFound {
        return .deviceNotFound(udid: e.udid)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceNotTrusted {
        return .deviceNotTrusted(udid: e.udid, name: e.name)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorDeviceDisconnected {
        return .deviceDisconnected(udid: e.udid, during: e.during)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorExtractionFailed {
        return .extractionFailed(bundleID: e.bundleID, reason: e.reason)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInstallFailed {
        return .installFailed(bundleID: e.bundleID, reason: e.reason)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorIpaFileNotFound {
        return .ipaFileNotFound(path: e.path)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorArchiveWriteFailed {
        return .archiveWriteFailed(path: e.path, reason: e.reason)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorProcessExitedWithError {
        return .processExitedWithError(tool: e.tool, exitCode: e.exitCode, stderr: e.stderr)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorProcessTimeout {
        return .processTimeout(tool: e.tool, timeout: e.timeout)
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorAppListParseFailed {
        return .appListParseFailed(reason: e.reason, rawOutput: e.rawOutput)
    }

    if kotlinException is SpaSpacieError.SpaSpacieErrorCancelled {
        return .cancelled
    }

    if let e = kotlinException as? SpaSpacieError.SpaSpacieErrorInsufficientDiskSpace {
        let required = e.required >= 0 ? UInt64(e.required) : 0
        let available = e.available >= 0 ? UInt64(e.available) : 0
        return .insufficientDiskSpace(required: required, available: available)
    }

    // Generic fallback: surface the error's localised description.
    return .processExitedWithError(
        tool: "KMP",
        exitCode: Int32(nsError.code),
        stderr: error.localizedDescription
    )
}
