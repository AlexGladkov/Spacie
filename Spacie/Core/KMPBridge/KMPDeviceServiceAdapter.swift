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

    // nonisolated(unsafe) — KMP ObjC types are not Sendable; needed for deinit access.
    nonisolated(unsafe) private let kmpService: any SpaDeviceServiceApi
    /// Last-known Apple-ID auth flag. Stored so a cancelled `checkAppleIDAuth`
    /// can return the prior value instead of regressing to `false`, which
    /// rendered a spurious "Sign in" prompt after sheet dismiss-reopen.
    private let cachedAppleIDAuth = CachedBool(value: false)

    /// Default initializer wires the production KMP factory.
    init() {
        self.kmpService = SpaSpacieFactory.shared.createDeviceService()
    }

    /// Test/preview initializer that accepts a pre-built KMP service.
    ///
    /// Allows unit tests to inject a fake `SpaDeviceServiceApi` (e.g. constructed
    /// with a `FakeProcessRunner` via `SpaSpacieFactory` overrides) so the
    /// adapter's error mapping, polling loop, and transfer orchestration can be
    /// exercised without spawning real binaries.
    init(kmpService: any SpaDeviceServiceApi) {
        self.kmpService = kmpService
    }

    /// Cancels the underlying KMP coroutine scope and stops any ongoing observation
    /// or transfer streams. Call from owner's `deinit` (or when the adapter is no
    /// longer needed) to release KMP-side resources promptly.
    ///
    /// `deinit` also calls this as a safety net, but prefer explicit `shutdown()`
    /// so cancellation isn't tied to ARC timing of streams that retain the adapter.
    nonisolated func shutdown() {
        kmpService.cancel()
    }

    deinit {
        kmpService.cancel()
    }

    // MARK: - checkDependencies

    func checkDependencies() async -> DependencyStatus {
        // KMP converts coroutine cancellation into a non-nil NSError with a
        // nil status. Treating that as `.homebrewMissing` (as the previous
        // implementation did) made the next sheet open display a spurious
        // "Homebrew not installed" prompt after the user merely dismissed the
        // wizard mid-check. We surface cancellation as `.checking`-equivalent
        // by returning the last known idle state.
        await withCheckedContinuation { continuation in
            kmpService.checkDependencies { kmpStatus, error in
                if let kmpStatus {
                    continuation.resume(returning: kmpStatus.toSwift())
                    return
                }
                // Distinguish cancellation from real "no homebrew" by
                // inspecting the underlying KMP exception type. The Swift
                // overlay for `kotlinx.coroutines.CancellationException` is
                // exposed as `KotlinCancellationException`; using a runtime
                // type-name match avoids a direct import dependency.
                if let error, Self.isKotlinCancellation(error) {
                    // No "cancelled" variant on DependencyStatus; the safest
                    // observable shape on a benign cancel is `missing(tools:
                    // [])` — UI treats it as an incomplete check rather than
                    // a definitive "Homebrew not installed".
                    continuation.resume(returning: .missing(tools: []))
                } else {
                    continuation.resume(returning: .homebrewMissing)
                }
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
                    continuation.resume(throwing: KMPErrorMapper.map(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - checkAppleIDAuth

    func checkAppleIDAuth() async -> Bool {
        // The cancellation path returns the LAST known authenticated state
        // via the dedicated `cachedAppleIDAuth` flag. Returning `false`
        // outright (as the previous commit did) reproduced the same flicker
        // the comment claimed to fix: after dismiss-reopen the wizard
        // briefly showed "Sign in" even when the user was already
        // authenticated.
        await withCheckedContinuation { continuation in
            kmpService.checkAppleIDAuth { [cachedAppleIDAuth] kotlinBool, error in
                if let kotlinBool {
                    let value = kotlinBool.boolValue
                    cachedAppleIDAuth.update(value)
                    continuation.resume(returning: value)
                    return
                }
                if let error, Self.isKotlinCancellation(error) {
                    // Preserve last known good value across cancel.
                    continuation.resume(returning: cachedAppleIDAuth.read())
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - loginAppleID

    func loginAppleID(email: String, password: String, authCode: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            kmpService.loginAppleID(email: email, password: password, authCode: authCode) { error in
                if let error {
                    continuation.resume(throwing: KMPErrorMapper.map(error))
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
                    continuation.resume(throwing: KMPErrorMapper.map(error))
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
            // [weak self]: stream must not retain the adapter; if the owner releases
            // the adapter, the next polling tick observes self == nil and finishes.
            let task = Task.detached { [weak self] in
                var knownUDIDs = Set<String>()
                var knownTrustStates: [String: TrustState] = [:]

                while !Task.isCancelled {
                    guard let self else {
                        continuation.finish()
                        return
                    }

                    let devices: [DeviceInfo]
                    do {
                        devices = try await self.listDevices()
                    } catch {
                        continuation.yield(.error(error))
                        try? await Task.sleep(nanoseconds: UInt64(clampedInterval * 1_000_000_000))
                        continue
                    }

                    // Poll trust state for connected devices in parallel to avoid
                    // sequential N×validateTrust latency drift in the polling cadence.
                    //
                    // IMPORTANT: a nil `self` in the child task (adapter
                    // released between iterations) must NOT collapse to
                    // `.notTrusted` — that would spuriously revert
                    // already-`.trusted` devices and have consumers re-prompt
                    // for trust. Skip the entry instead so the diff treats it
                    // as "unchanged" (last known state retained).
                    let trustResults: [(String, TrustState)] = await withTaskGroup(of: (String, TrustState)?.self) { group in
                        for device in devices {
                            group.addTask { [weak self] in
                                guard let self else { return nil }
                                // Use the optional variant — a nil result
                                // (KMP error/cancel) is treated as "unknown
                                // this tick" and skipped, preserving the last
                                // known trust state in the differ rather than
                                // synthesising .notTrusted.
                                guard let state = await self.validateTrustOptional(udid: device.udid) else { return nil }
                                return (device.udid, state)
                            }
                        }
                        var collected: [(String, TrustState)] = []
                        for await pair in group {
                            if let pair { collected.append(pair) }
                        }
                        return collected
                    }

                    // Pure diff: builds the event list and the next known sets.
                    // Extracted so the polling rules are unit-testable.
                    let diffResult = DevicePollDiffer.diff(
                        knownUDIDs: knownUDIDs,
                        knownTrustStates: knownTrustStates,
                        currentDevices: devices,
                        trustResults: trustResults
                    )
                    for event in diffResult.events {
                        continuation.yield(event)
                    }
                    knownUDIDs = diffResult.nextKnownUDIDs
                    knownTrustStates = diffResult.nextKnownTrustStates

                    // Detect cancellation through the sleep — `try?` would
                    // swallow it and let the polling loop run one extra
                    // tick after cancel. Bail explicitly.
                    do {
                        try await Task.sleep(nanoseconds: UInt64(clampedInterval * 1_000_000_000))
                    } catch {
                        break
                    }
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
        await validateTrustOptional(udid: udid) ?? .notTrusted
    }

    /// Variant that distinguishes "validate succeeded" from "validate failed
    /// or was cancelled". The polling loop uses this so a transient KMP
    /// failure or coroutine cancellation does not collapse to `.notTrusted`
    /// and trigger a spurious revert event for an already-trusted device.
    private func validateTrustOptional(udid: String) async -> TrustState? {
        await withCheckedContinuation { continuation in
            kmpService.validateTrust(udid: udid) { kmpState, error in
                if let kmpState {
                    continuation.resume(returning: kmpState.toSwift())
                } else {
                    // Either KMP returned nil with an error (cancellation /
                    // device went away) or with no error (shouldn't happen).
                    // Either way: don't synthesise a state.
                    _ = error
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - listApps

    func listApps(udid: String) async throws -> [AppInfo] {
        try await withCheckedThrowingContinuation { continuation in
            kmpService.listApps(udid: udid) { kmpApps, error in
                if let error {
                    continuation.resume(throwing: KMPErrorMapper.map(error))
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
                        continuation.resume(throwing: KMPErrorMapper.map(error))
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
                        continuation.resume(throwing: KMPErrorMapper.map(error))
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
            // Holder allows the progress closure (called from KMP off-actor) to mutate
            // items under lock and emit fresh snapshots without capturing a mutable var.
            let holder = TransferItemsHolder(apps.map { TransferItem(id: $0.bundleID, app: $0) })
            // [weak self]: stream must not retain the adapter.
            let task = Task.detached { [weak self] in
                let tempBase = FileManager.default.temporaryDirectory
                let totalCount = apps.count

                for i in 0..<totalCount {
                    if Task.isCancelled {
                        continuation.finish(throwing: iMobileDeviceError.cancelled)
                        return
                    }
                    guard let self else {
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
                    let extractingSnapshot = holder.update(at: i) {
                        $0.phase = .extracting
                        $0.progress = 0.0
                    }
                    continuation.yield(TransferProgress(items: extractingSnapshot, currentItemIndex: i))

                    do {
                        let bundleID = holder.snapshot()[i].app.bundleID
                        let ipaURL = try await self.extractIPA(
                            udid: sourceUDID,
                            bundleID: bundleID,
                            destinationDir: tempDir,
                            progressHandler: { progress in
                                let snap = holder.update(at: i) { $0.progress = progress }
                                continuation.yield(TransferProgress(items: snap, currentItemIndex: i))
                            }
                        )

                        // Disk-space pre-flight: refuse to proceed with
                        // archiving if the destination volume cannot hold
                        // the just-extracted IPA + a 10 MiB safety margin.
                        // The Swift adapter bypasses AppArchiveService.archiveIPA
                        // (which has this check), so on a nearly-full volume
                        // a batch transfer would otherwise silently fill
                        // the disk.
                        //
                        // Guards:
                        //  - clamp `fileSize` to non-negative before UInt64
                        //    cast (negative values would trap)
                        //  - check available even when ipaSize == 0 (stat
                        //    can race the extract; still refuse if the
                        //    volume has less than the safety margin)
                        if let archiveDir {
                            let rawSize = (try? ipaURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                            let ipaSize: UInt64 = rawSize > 0 ? UInt64(rawSize) : 0
                            let availRaw = (try? archiveDir.resourceValues(
                                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                            ).volumeAvailableCapacityForImportantUsage) ?? 0
                            let avail: UInt64 = availRaw > 0 ? UInt64(availRaw) : 0
                            if avail < ipaSize + 10_485_760 {
                                let snap = holder.update(at: i) {
                                    $0.phase = .failed
                                    $0.error = .insufficientDiskSpace(
                                        required: ipaSize + 10_485_760,
                                        available: avail
                                    )
                                }
                                continuation.yield(TransferProgress(items: snap, currentItemIndex: i))
                                continue
                            }
                        }

                        // Phase: archiving (optional)
                        if let archiveDir {
                            let snap = holder.update(at: i) {
                                $0.phase = .archiving
                                $0.progress = 0.0
                            }
                            continuation.yield(TransferProgress(items: snap, currentItemIndex: i))

                            let app = apps[i]
                            let destDir = archiveDir.appendingPathComponent(UUID().uuidString)
                            do {
                                let fm = FileManager.default
                                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destDir.path)

                                // Sanitize the source file name before reusing it as the
                                // archive entry's IPA file. `ipaURL` originated outside our
                                // process (extraction output) and `lastPathComponent` could
                                // technically contain `..` or path separators. Pin the IPA
                                // name to a deterministic, safe value derived from the bundle ID.
                                let safeFileName = Self.sanitizeIPAFileName(
                                    bundleID: app.bundleID,
                                    sourceLastComponent: ipaURL.lastPathComponent
                                )
                                let destIPA = destDir.appendingPathComponent(safeFileName)
                                try fm.copyItem(at: ipaURL, to: destIPA)
                                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destIPA.path)

                                // Persist metadata.json so the archive is visible in Archive Library.
                                // AppArchiveService.listArchivedApps silently skips entries missing this file.
                                // Clamp non-negative before UInt64 cast —
                                // negative Int would trap.
                                let rawDestSize = (try? destIPA.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                                let ipaSize: UInt64 = rawDestSize > 0 ? UInt64(rawDestSize) : 0
                                let metadata = ArchivedAppMetadata(
                                    bundleID: app.bundleID,
                                    displayName: app.displayName,
                                    version: app.version,
                                    shortVersion: app.shortVersion,
                                    ipaSize: ipaSize,
                                    archivedAt: Date(),
                                    sourceDeviceName: nil,
                                    sourceDeviceVersion: nil
                                )
                                let encoder = JSONEncoder()
                                encoder.dateEncodingStrategy = .iso8601
                                let metadataData = try encoder.encode(metadata)
                                let metadataURL = destDir.appendingPathComponent("metadata.json")
                                try metadataData.write(to: metadataURL, options: .atomic)
                                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)

                                if let iconData = app.iconData {
                                    let iconURL = destDir.appendingPathComponent("icon.png")
                                    try? iconData.write(to: iconURL, options: .atomic)
                                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: iconURL.path)
                                }
                            } catch {
                                // Best-effort cleanup of partial archive entry.
                                try? FileManager.default.removeItem(at: destDir)
                                throw iMobileDeviceError.archiveWriteFailed(
                                    path: destDir.path,
                                    reason: error.localizedDescription
                                )
                            }
                        }

                        // Phase: installing (optional)
                        if shouldInstall, let destUDID = destinationUDID {
                            let snap = holder.update(at: i) {
                                $0.phase = .installing
                                $0.progress = 0.0
                            }
                            continuation.yield(TransferProgress(items: snap, currentItemIndex: i))
                            try await self.installIPA(
                                udid: destUDID,
                                ipaPath: ipaURL,
                                progressHandler: { progress in
                                    let snap = holder.update(at: i) { $0.progress = progress }
                                    continuation.yield(TransferProgress(items: snap, currentItemIndex: i))
                                }
                            )
                        }

                        let completedSnap = holder.update(at: i) {
                            $0.phase = .completed
                            $0.progress = 1.0
                        }
                        continuation.yield(TransferProgress(items: completedSnap, currentItemIndex: i))

                    } catch let deviceError as iMobileDeviceError {
                        let failedSnap = holder.update(at: i) {
                            $0.phase = .failed
                            $0.error = deviceError
                        }
                        continuation.yield(TransferProgress(items: failedSnap, currentItemIndex: i))
                    } catch {
                        let bundleID = holder.snapshot()[i].app.bundleID
                        let failedSnap = holder.update(at: i) {
                            $0.phase = .failed
                            $0.error = .extractionFailed(
                                bundleID: bundleID,
                                reason: error.localizedDescription
                            )
                        }
                        continuation.yield(TransferProgress(items: failedSnap, currentItemIndex: i))
                    }
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - CachedBool

/// Tiny thread-safe holder used by [KMPDeviceServiceAdapter.checkAppleIDAuth]
/// to preserve the previously observed value across cancellations.
private final class CachedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(value: Bool) { self.value = value }
    func read() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func update(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}

// MARK: - Path sanitization

extension KMPDeviceServiceAdapter {
    /// Returns a safe file name for the archived IPA. Rejects path
    /// separators, `..`, embedded NUL, and any non-ASCII control bytes that
    /// could let the extraction-side last-path-component escape `destDir`.
    /// Falls back to `<bundleID>.ipa` when the source name is unsafe.
    fileprivate static func sanitizeIPAFileName(bundleID: String, sourceLastComponent: String) -> String {
        let trimmed = sourceLastComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsTraversal = trimmed.contains("/")
            || trimmed.contains("\\")
            || trimmed.contains("\u{0}")
            || trimmed == ".."
            || trimmed.hasPrefix("..")
            || trimmed.hasPrefix(".")
            || trimmed.isEmpty
        if containsTraversal {
            return "\(bundleID).ipa"
        }
        return trimmed
    }
}

// MARK: - Cancellation detection helper

extension KMPDeviceServiceAdapter {
    /// Returns `true` when the NSError surfaced by a KMP completion handler
    /// originated from a `kotlinx.coroutines.CancellationException`. Uses
    /// runtime type-name introspection so the file does not have to import
    /// the KMP-generated `KotlinCancellationException` Swift overlay.
    fileprivate static func isKotlinCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard let kotlinException = nsError.kotlinException else { return false }
        let typeName = String(describing: type(of: kotlinException))
        return typeName.contains("CancellationException")
    }
}

// MARK: - TransferItemsHolder

/// Thread-safe mutable container for `[TransferItem]` shared between the orchestration
/// task and KMP progress callbacks (which fire on arbitrary off-actor threads).
///
/// Uses `NSLock` rather than an actor to keep call sites synchronous — progress
/// closures are non-async and emit snapshots inline.
private final class TransferItemsHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TransferItem]

    init(_ items: [TransferItem]) {
        self.items = items
    }

    func snapshot() -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    @discardableResult
    func update(at index: Int, mutation: (inout TransferItem) -> Void) -> [TransferItem] {
        lock.lock()
        defer { lock.unlock() }
        mutation(&items[index])
        return items
    }
}

// Model conversions (SpaDeviceInfo, SpaAppInfo, SpaTrustState, SpaDependencyStatus)
// are in DeviceModelConversions.swift

