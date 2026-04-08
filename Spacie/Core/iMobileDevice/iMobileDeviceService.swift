import Foundation

// MARK: - iMobileDeviceService

/// Actor-isolated implementation of ``iMobileDeviceProtocol`` that shells out
/// to `libimobiledevice` CLI tools discovered by ``HomebrewResolver``.
///
/// All device communication goes through ``ProcessRunner``. Inputs are validated
/// by ``InputValidator`` before being interpolated into CLI arguments.
///
/// ## Thread Safety
/// `iMobileDeviceService` is an `actor`, so all mutable state is protected by
/// Swift's actor isolation. Methods that return streaming types (`observeDevices`,
/// `transferApps`) are `nonisolated` and spawn unstructured `Task`s that call
/// back into the actor's isolated methods via `await`.
actor iMobileDeviceService: iMobileDeviceProtocol {

    // MARK: - Stored Properties

    private let runner: ProcessRunner
    private let resolver: HomebrewResolver

    // MARK: - Init

    init() {
        runner = ProcessRunner()
        resolver = HomebrewResolver()
    }

    // MARK: - Dependencies

    func checkDependencies() async -> DependencyStatus {
        await resolver.resolveAll()
    }

    func installDependencies(
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let brewPath = await resolver.resolve("brew") else {
            throw iMobileDeviceError.homebrewNotInstalled
        }

        let result = try await runner.runWithLineOutput(
            executablePath: brewPath,
            arguments: ["install", "libimobiledevice", "ideviceinstaller", "ipatool"],
            timeout: 300,
            onLine: onLine
        )

        if result.exitCode != 0 {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw iMobileDeviceError.dependencyInstallFailed(
                reason: stderr.isEmpty ? "Exit code \(result.exitCode)" : stderr
            )
        }

        await resolver.invalidateCache()
    }

    // MARK: - Device Discovery

    func listDevices() async throws -> [DeviceInfo] {
        let paths = try await requireToolPaths()

        let result = try await runner.run(
            executablePath: paths.ideviceId,
            arguments: ["-l"],
            timeout: 10
        )

        let output = String(data: result.stdout, encoding: .utf8) ?? ""
        let udids = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var devices: [DeviceInfo] = []
        for udid in udids {
            guard (try? InputValidator.validateUDID(udid)) != nil else { continue }
            if let info = try? await fetchDeviceInfo(udid: udid, paths: paths) {
                devices.append(info)
            }
        }
        return devices
    }

    nonisolated func observeDevices(
        pollingInterval: TimeInterval
    ) -> AsyncStream<DeviceEvent> {
        let interval = max(1.0, pollingInterval)
        let service = self
        return AsyncStream { continuation in
            let task = Task {
                var knownUDIDs: Set<String> = []
                var knownTrustStates: [String: TrustState] = [:]
                while !Task.isCancelled {
                    do {
                        let devices = try await service.listDevices()
                        let currentUDIDs = Set(devices.map(\.udid))

                        for device in devices where !knownUDIDs.contains(device.udid) {
                            continuation.yield(.connected(device))
                        }
                        for udid in knownUDIDs where !currentUDIDs.contains(udid) {
                            continuation.yield(.disconnected(udid: udid))
                            knownTrustStates.removeValue(forKey: udid)
                        }
                        knownUDIDs = currentUDIDs

                        // Poll trust state for every connected device so that
                        // tapping "Trust" on the iPhone is detected promptly.
                        for device in devices {
                            let newState = await service.validateTrust(udid: device.udid)
                            if knownTrustStates[device.udid] != newState {
                                knownTrustStates[device.udid] = newState
                                continuation.yield(.trustStateChanged(udid: device.udid, state: newState))
                            }
                        }
                    } catch {
                        continuation.yield(.error(error))
                    }
                    try? await Task.sleep(for: .seconds(interval))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Trust

    func validateTrust(udid: String) async -> TrustState {
        guard (try? InputValidator.validateUDID(udid)) != nil else { return .notTrusted }
        guard let paths = try? await requireToolPaths() else { return .notTrusted }

        guard let result = try? await runner.run(
            executablePath: paths.idevicepair,
            arguments: ["validate", "-u", udid],
            timeout: 5
        ) else { return .notTrusted }

        let output = (
            (String(data: result.stdout, encoding: .utf8) ?? "") +
            (String(data: result.stderr, encoding: .utf8) ?? "")
        ).lowercased()

        if result.exitCode == 0 || output.contains("success") || output.contains("validated") {
            return .trusted
        } else if output.contains("dialog_response_pending") || output.contains("pairing_dialog") {
            return .dialogShown
        }
        return .notTrusted
    }

    // MARK: - App Management

    func listApps(udid: String) async throws -> [AppInfo] {
        try InputValidator.validateUDID(udid)
        let paths = try await requireToolPaths()

        let result = try await runner.run(
            executablePath: paths.ideviceinstaller,
            arguments: ["-u", udid, "list", "--xml"],
            timeout: 30
        )

        guard result.exitCode == 0 else {
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            throw iMobileDeviceError.processExitedWithError(
                tool: "ideviceinstaller",
                exitCode: result.exitCode,
                stderr: stderr
            )
        }

        return try Self.parseAppList(result.stdout)
    }

    // MARK: - IPA Extraction

    /// Downloads an IPA for the specified bundle ID from the App Store via ipatool.
    ///
    /// Requires the user to be signed in with an Apple ID (``checkAppleIDAuth()``
    /// must return `true`). The `udid` parameter is accepted for API compatibility
    /// but is not used — ipatool downloads the IPA directly from Apple's servers
    /// rather than extracting it from the connected device.
    func extractIPA(
        udid: String,
        bundleID: String,
        destinationDir: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try InputValidator.validateUDID(udid)
        try InputValidator.validateBundleID(bundleID)
        let paths = try await requireToolPaths()

        // Verify ipatool is authenticated before attempting download.
        guard await checkAppleIDAuth() else {
            throw iMobileDeviceError.extractionFailed(
                bundleID: bundleID,
                reason: "Not signed in with Apple ID. Please sign in first."
            )
        }

        let ipaURL = destinationDir.appendingPathComponent("\(bundleID).ipa")
        progressHandler(0.1)

        let result = try await runner.runWithLineOutput(
            executablePath: paths.ipatool,
            arguments: ["download", "-b", bundleID, "-o", ipaURL.path, "--purchase"],
            timeout: 300,
            onLine: { _ in progressHandler(0.5) }
        )

        if result.exitCode != 0 {
            let raw = [
                String(data: result.stdout, encoding: .utf8) ?? "",
                String(data: result.stderr, encoding: .utf8) ?? ""
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            let out = Self.stripANSI(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            throw iMobileDeviceError.extractionFailed(
                bundleID: bundleID,
                reason: out.isEmpty ? "ipatool exited with code \(result.exitCode)" : out
            )
        }

        guard FileManager.default.fileExists(atPath: ipaURL.path) else {
            throw iMobileDeviceError.extractionFailed(
                bundleID: bundleID,
                reason: "IPA was not downloaded to expected path"
            )
        }

        progressHandler(1.0)
        return ipaURL
    }

    // MARK: - Apple ID Authentication

    /// Returns `true` if ipatool reports a valid authenticated session.
    ///
    /// Runs `ipatool auth info` with a short timeout. A zero exit code means
    /// the stored credentials are valid.
    func checkAppleIDAuth() async -> Bool {
        guard let paths = try? await requireToolPaths() else { return false }
        let result = try? await runner.run(
            executablePath: paths.ipatool,
            arguments: ["auth", "info"],
            timeout: 10
        )
        return result?.exitCode == 0
    }

    /// Authenticates ipatool with the given Apple ID credentials.
    ///
    /// Credentials are passed as CLI flags and are never written to disk by
    /// this code; ipatool itself stores the session token in the system keychain.
    func loginAppleID(email: String, password: String, authCode: String?) async throws {
        let paths = try await requireToolPaths()
        var args = ["auth", "login", "--email", email, "--password", password]
        if let code = authCode, !code.isEmpty {
            args += ["--auth-code", code]
        }
        let result = try await runner.run(
            executablePath: paths.ipatool,
            arguments: args,
            timeout: 30
        )
        if result.exitCode != 0 {
            let rawOutput = [
                String(data: result.stdout, encoding: .utf8) ?? "",
                String(data: result.stderr, encoding: .utf8) ?? ""
            ].filter { !$0.isEmpty }.joined(separator: "\n")
            let cleaned = Self.stripANSI(rawOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = cleaned.lowercased()
            // Detect 2FA requirement from ipatool output.
            let twoFAKeywords = ["two-factor", "2fa", "auth-code", "authentication code",
                                 "verification code", "two factor", "mfa", "requires code",
                                 "second factor", "one-time"]
            if authCode == nil, twoFAKeywords.contains(where: { lowered.contains($0) }) {
                throw iMobileDeviceError.twoFactorRequired
            }
            throw iMobileDeviceError.authFailed(
                reason: cleaned.isEmpty ? "Authentication failed" : cleaned
            )
        }
    }

    // MARK: - IPA Installation

    func installIPA(
        udid: String,
        ipaPath: URL,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        try InputValidator.validateUDID(udid)

        guard FileManager.default.fileExists(atPath: ipaPath.path) else {
            throw iMobileDeviceError.ipaFileNotFound(path: ipaPath.path)
        }

        let paths = try await requireToolPaths()

        do {
            let result = try await runner.runWithLineOutput(
                executablePath: paths.ideviceinstaller,
                arguments: ["-u", udid, "install", ipaPath.path],
                timeout: 120,
                onLine: { line in
                    if let progress = iMobileDeviceService.parseProgressLine(line) {
                        progressHandler(progress)
                    }
                }
            )

            if result.exitCode != 0 {
                let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
                throw iMobileDeviceError.installFailed(
                    bundleID: ipaPath.deletingPathExtension().lastPathComponent,
                    reason: stderr
                )
            }
        } catch ProcessRunnerError.cancelled {
            throw iMobileDeviceError.cancelled
        } catch ProcessRunnerError.timeout(let tool, let seconds) {
            throw iMobileDeviceError.processTimeout(tool: tool, timeout: seconds)
        } catch let err as iMobileDeviceError {
            throw err
        } catch {
            throw iMobileDeviceError.installFailed(
                bundleID: ipaPath.deletingPathExtension().lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Batch Transfer

    nonisolated func transferApps(
        sourceUDID: String,
        destinationUDID: String?,
        apps: [AppInfo],
        archiveDir: URL?,
        shouldInstall: Bool
    ) -> AsyncThrowingStream<TransferProgress, Error> {
        let service = self
        return AsyncThrowingStream { continuation in
            let task = Task {
                var items = apps.map { TransferItem(id: $0.bundleID, app: $0) }

                for i in items.indices {
                    guard !Task.isCancelled else {
                        continuation.finish(throwing: iMobileDeviceError.cancelled)
                        return
                    }

                    let app = items[i].app
                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)

                    // Defer ensures temp directory is cleaned up after each app,
                    // regardless of success or failure.
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    do {
                        try FileManager.default.createDirectory(
                            at: tempDir,
                            withIntermediateDirectories: true
                        )
                    } catch {
                        items[i].phase = .failed
                        items[i].error = .archiveWriteFailed(
                            path: tempDir.path,
                            reason: error.localizedDescription
                        )
                        continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                        continue
                    }

                    // Phase 1: Extract
                    items[i].phase = .extracting
                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))

                    let ipaURL: URL
                    do {
                        ipaURL = try await service.extractIPA(
                            udid: sourceUDID,
                            bundleID: app.bundleID,
                            destinationDir: tempDir,
                            progressHandler: { _ in }
                        )
                    } catch {
                        let mapped = error as? iMobileDeviceError
                            ?? .extractionFailed(bundleID: app.bundleID, reason: error.localizedDescription)
                        if case .cancelled = mapped {
                            continuation.finish(throwing: mapped)
                            return
                        }
                        items[i].phase = .failed
                        items[i].error = mapped
                        continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                        continue
                    }

                    // Phase 2: Archive
                    if let archiveDir {
                        items[i].phase = .archiving
                        continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                        do {
                            try iMobileDeviceService.writeToArchive(
                                ipaURL: ipaURL,
                                app: app,
                                archiveDir: archiveDir
                            )
                        } catch {
                            items[i].phase = .failed
                            items[i].error = .archiveWriteFailed(
                                path: archiveDir.path,
                                reason: error.localizedDescription
                            )
                            continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                            continue
                        }
                    }

                    // Phase 3: Install
                    if shouldInstall, let destinationUDID {
                        items[i].phase = .installing
                        continuation.yield(TransferProgress(items: items, currentItemIndex: i))

                        do {
                            try await service.installIPA(
                                udid: destinationUDID,
                                ipaPath: ipaURL,
                                progressHandler: { _ in }
                            )
                        } catch {
                            let mapped = error as? iMobileDeviceError
                                ?? .installFailed(bundleID: app.bundleID, reason: error.localizedDescription)
                            if case .cancelled = mapped {
                                continuation.finish(throwing: mapped)
                                return
                            }
                            items[i].phase = .failed
                            items[i].error = mapped
                            continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                            continue
                        }
                    }

                    items[i].phase = .completed
                    items[i].progress = 1.0
                    continuation.yield(TransferProgress(items: items, currentItemIndex: i))
                }

                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Private Helpers

    /// Strips ANSI terminal escape sequences (e.g. `\e[31m`) from a string.
    ///
    /// ipatool outputs coloured terminal text; stripping the codes prevents
    /// escape sequences from appearing in user-visible error messages.
    private static func stripANSI(_ string: String) -> String {
        string.replacing(/\x1B\[[0-9;]*[mGKHFJA-Z]/, with: "")
    }

    /// Returns resolved tool paths or throws an appropriate ``iMobileDeviceError``.
    private func requireToolPaths() async throws -> ToolPaths {
        switch await resolver.resolveAll() {
        case .ready(let paths):
            return paths
        case .missing(let tools):
            throw iMobileDeviceError.dependencyMissing(tools)
        case .homebrewMissing:
            throw iMobileDeviceError.homebrewNotInstalled
        }
    }

    /// Fetches device metadata via `ideviceinfo -u <udid>`.
    private func fetchDeviceInfo(udid: String, paths: ToolPaths) async throws -> DeviceInfo {
        let result = try await runner.run(
            executablePath: paths.ideviceInfo,
            arguments: ["-u", udid],
            timeout: 5
        )
        let dict = Self.parseKeyValueOutput(
            String(data: result.stdout, encoding: .utf8) ?? ""
        )
        return DeviceInfo(
            udid: udid,
            deviceName: InputValidator.sanitizeDisplayName(
                dict["DeviceName"] ?? udid,
                maxLength: 100
            ),
            productType: dict["ProductType"] ?? "Unknown",
            productVersion: dict["ProductVersion"] ?? "Unknown",
            buildVersion: dict["BuildVersion"] ?? "Unknown"
        )
    }

    /// Splits `"Key: Value\n..."` output into a dictionary.
    private static func parseKeyValueOutput(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Parses the XML plist produced by `ideviceinstaller list --xml`.
    ///
    /// `ideviceinstaller list` (without `--all`) already returns only user-installed
    /// apps, so no additional filtering is needed here.
    private static func parseAppList(_ data: Data) throws -> [AppInfo] {
        guard !data.isEmpty else { return [] }

        let plist: Any
        do {
            plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw iMobileDeviceError.appListParseFailed(
                reason: error.localizedDescription,
                rawOutput: String(data: data.prefix(500), encoding: .utf8) ?? ""
            )
        }

        guard let dicts = plist as? [[String: Any]] else {
            throw iMobileDeviceError.appListParseFailed(
                reason: "Expected array of dictionaries at plist root",
                rawOutput: String(data: data.prefix(500), encoding: .utf8) ?? ""
            )
        }

        return dicts.compactMap { dict -> AppInfo? in
            guard let bundleID = dict["CFBundleIdentifier"] as? String,
                  (try? InputValidator.validateBundleID(bundleID)) != nil
            else { return nil }

            let displayName = (dict["CFBundleDisplayName"] as? String)
                ?? (dict["CFBundleName"] as? String)
                ?? bundleID
            let version = (dict["CFBundleVersion"] as? String) ?? "0"
            let shortVersion = (dict["CFBundleShortVersionString"] as? String) ?? version
            let ipaSize: UInt64? = (dict["StaticDiskUsage"] as? UInt64)
                ?? (dict["StaticDiskUsage"] as? Int).map(UInt64.init)

            return AppInfo(
                bundleID: bundleID,
                displayName: InputValidator.sanitizeDisplayName(displayName, maxLength: 100),
                version: version,
                shortVersion: shortVersion,
                ipaSize: ipaSize,
                iconData: nil
            )
        }
    }

    /// Extracts a percentage value (0.0...1.0) from an ideviceinstaller progress line.
    ///
    /// Matches patterns like `"10%"`, `"50.00%"`, `"Installing: 75%"`.
    private static func parseProgressLine(_ line: String) -> Double? {
        let pattern = /(\d+(?:\.\d+)?)\s*%/
        guard let match = line.firstMatch(of: pattern) else { return nil }
        guard let value = Double(String(match.output.1)) else { return nil }
        return min(1.0, value / 100.0)
    }

    /// Copies an IPA and writes `metadata.json` (and optionally `icon.png`)
    /// into a new UUID-named directory inside `archiveDir`.
    private static func writeToArchive(
        ipaURL: URL,
        app: AppInfo,
        archiveDir: URL
    ) throws {
        // Ensure the root archive directory exists before safeArchivePath validates it.
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let (archiveDirectory, archiveIPA) = try InputValidator.safeArchivePath(
            archiveDir: archiveDir,
            displayName: app.displayName
        )
        try FileManager.default.createDirectory(
            at: archiveDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: ipaURL, to: archiveIPA)

        // Set restrictive permissions (owner read/write only).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: archiveIPA.path
        )

        let ipaSize: UInt64
        if let fileSize = try? archiveIPA.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            ipaSize = UInt64(fileSize)
        } else {
            ipaSize = 0
        }

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
        try metadataData.write(
            to: archiveDirectory.appendingPathComponent("metadata.json"),
            options: .atomic
        )

        if let iconData = app.iconData {
            try iconData.write(
                to: archiveDirectory.appendingPathComponent("icon.png"),
                options: .atomic
            )
        }
    }
}
