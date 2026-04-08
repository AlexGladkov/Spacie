import Foundation

// MARK: - AppArchiveProtocol

/// Manages the local IPA archive — a library of extracted apps stored on disk.
///
/// Archive operations are purely local filesystem work and do not require a
/// connected device. This separation allows the archive UI to function
/// independently of the transfer wizard.
///
/// ## Directory Layout
/// ```
/// ~/Library/Application Support/Spacie/Archives/
///   <UUID>/
///     metadata.json   — ArchivedAppMetadata (ISO‑8601 dates)
///     icon.png        — 60×60 app icon (optional)
///     <AppName>.ipa   — the extracted IPA
/// ```
///
/// Each archive entry occupies a UUID-named directory to prevent path-traversal
/// attacks and naming collisions.
protocol AppArchiveProtocol: Sendable {

    /// Root directory that stores all archive entries.
    var archiveDirectory: URL { get }

    /// Returns all archived apps, sorted by `archivedAt` descending (newest first).
    ///
    /// Entries with a missing or unreadable `metadata.json` are silently skipped.
    func listArchivedApps() async throws -> [ArchivedApp]

    /// Saves an IPA and its metadata into the archive.
    ///
    /// - Parameters:
    ///   - ipaPath: Source IPA file URL. Must exist on disk.
    ///   - metadata: Metadata to persist alongside the IPA.
    ///   - overwrite: When `true`, an existing archive with the same bundle ID
    ///     and version is replaced. When `false`, the method throws
    ///     ``iMobileDeviceError/archiveWriteFailed(path:reason:)`` if a duplicate
    ///     is detected.
    /// - Returns: File URL of the newly archived IPA inside the archive directory.
    func archiveIPA(
        ipaPath: URL,
        metadata: ArchivedAppMetadata,
        overwrite: Bool
    ) async throws -> URL

    /// Deletes a single archive entry identified by its UUID.
    ///
    /// - Parameter id: The `ArchivedApp.id` (UUID string) to remove.
    /// - Throws: ``iMobileDeviceError/archiveWriteFailed(path:reason:)`` if the
    ///   directory cannot be removed.
    func deleteArchive(id: String) async throws

    /// Returns the total size in bytes of all files under ``archiveDirectory``.
    func totalArchiveSize() async throws -> UInt64
}

// MARK: - AppArchiveService

/// Actor-isolated implementation of ``AppArchiveProtocol``.
///
/// The archive directory is created lazily on first write. Reads are safe to
/// call when the directory does not yet exist (returns empty array or zero).
actor AppArchiveService: AppArchiveProtocol {

    // MARK: - archiveDirectory

    /// Default archive location: `~/Library/Application Support/Spacie/Archives/`.
    ///
    /// Exposed as `static` so that the Settings UI can display the fallback path
    /// without instantiating an `AppArchiveService`.
    nonisolated static var defaultArchiveDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        return appSupport
            .appendingPathComponent("Spacie", isDirectory: true)
            .appendingPathComponent("Archives", isDirectory: true)
    }

    /// Root directory for IPA archives.
    ///
    /// Returns the user-configured path (stored under `"iOSArchiveDirectory"` in
    /// `UserDefaults`) when it is set and still points to a valid directory.
    /// Falls back to ``defaultArchiveDirectory`` otherwise.
    nonisolated var archiveDirectory: URL {
        if let customPath = UserDefaults.standard.string(forKey: "iOSArchiveDirectory"),
           !customPath.isEmpty {
            let url = URL(fileURLWithPath: customPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                return url
            }
        }
        return Self.defaultArchiveDirectory
    }

    // MARK: - listArchivedApps

    func listArchivedApps() async throws -> [ArchivedApp] {
        let root = archiveDirectory
        let fm = FileManager.default

        guard fm.fileExists(atPath: root.path) else { return [] }

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            throw iMobileDeviceError.archiveWriteFailed(
                path: root.path,
                reason: error.localizedDescription
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var apps: [ArchivedApp] = []
        for entry in contents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }

            let metadataURL = entry.appendingPathComponent("metadata.json")
            guard let metadataData = try? Data(contentsOf: metadataURL),
                  let metadata = try? decoder.decode(ArchivedAppMetadata.self, from: metadataData)
            else { continue }

            // Locate the IPA file inside the entry directory.
            guard let ipaURL = (try? fm.contentsOfDirectory(
                at: entry,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ))?.first(where: { $0.pathExtension.lowercased() == "ipa" })
            else { continue }

            let iconData = try? Data(contentsOf: entry.appendingPathComponent("icon.png"))

            apps.append(ArchivedApp(
                id: entry.lastPathComponent,
                metadata: metadata,
                ipaURL: ipaURL,
                iconData: iconData
            ))
        }

        return apps.sorted { $0.metadata.archivedAt > $1.metadata.archivedAt }
    }

    // MARK: - archiveIPA

    func archiveIPA(
        ipaPath: URL,
        metadata: ArchivedAppMetadata,
        overwrite: Bool
    ) async throws -> URL {
        let fm = FileManager.default
        let root = archiveDirectory

        guard fm.fileExists(atPath: ipaPath.path) else {
            throw iMobileDeviceError.ipaFileNotFound(path: ipaPath.path)
        }

        // Check available disk space.
        let ipaSize: UInt64
        if let fileSize = try? ipaPath.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            ipaSize = UInt64(fileSize)
        } else {
            ipaSize = 0
        }

        if let available = availableDiskSpace(at: root), available < ipaSize + 10_485_760 {
            throw iMobileDeviceError.insufficientDiskSpace(
                required: ipaSize + 10_485_760,
                available: available
            )
        }

        // If overwrite requested, remove any existing entry for the same bundleID/version.
        if overwrite {
            try await removeExistingEntry(bundleID: metadata.bundleID, version: metadata.version)
        } else {
            let existingApps = (try? await listArchivedApps()) ?? []
            if existingApps.contains(where: {
                $0.metadata.bundleID == metadata.bundleID &&
                $0.metadata.version == metadata.version
            }) {
                throw iMobileDeviceError.archiveWriteFailed(
                    path: root.path,
                    reason: "An archive for \(metadata.bundleID) v\(metadata.version) already exists. Pass overwrite: true to replace it."
                )
            }
        }

        // Create UUID-named entry directory.
        let (entryDirectory, archiveIPA) = try InputValidator.safeArchivePath(
            archiveDir: root,
            displayName: metadata.displayName
        )

        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try fm.createDirectory(at: entryDirectory, withIntermediateDirectories: true)

            // Restrictive directory permissions.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entryDirectory.path)

            try fm.copyItem(at: ipaPath, to: archiveIPA)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveIPA.path)
        } catch let err as iMobileDeviceError {
            throw err
        } catch {
            throw iMobileDeviceError.archiveWriteFailed(
                path: entryDirectory.path,
                reason: error.localizedDescription
            )
        }

        // Write metadata.json.
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let metadataData = try encoder.encode(metadata)
            let metadataURL = entryDirectory.appendingPathComponent("metadata.json")
            try metadataData.write(to: metadataURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        } catch {
            // Clean up on partial write.
            try? fm.removeItem(at: entryDirectory)
            throw iMobileDeviceError.archiveWriteFailed(
                path: entryDirectory.path,
                reason: "Failed to write metadata.json: \(error.localizedDescription)"
            )
        }

        return archiveIPA
    }

    // MARK: - deleteArchive

    func deleteArchive(id: String) async throws {
        let entryDir = archiveDirectory.appendingPathComponent(id, isDirectory: true)

        // Validate that id is a bare UUID (no path separators).
        guard !id.contains("/"), !id.contains(".."), !id.isEmpty else {
            throw iMobileDeviceError.archiveWriteFailed(
                path: entryDir.path,
                reason: "Invalid archive ID"
            )
        }

        guard FileManager.default.fileExists(atPath: entryDir.path) else { return }

        do {
            try FileManager.default.removeItem(at: entryDir)
        } catch {
            throw iMobileDeviceError.archiveWriteFailed(
                path: entryDir.path,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - totalArchiveSize

    func totalArchiveSize() async throws -> UInt64 {
        let root = archiveDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        return Self.recursiveSize(of: root)
    }

    // MARK: - Private Helpers

    /// Removes all archive entries matching `bundleID` + `version` (for overwrite).
    private func removeExistingEntry(bundleID: String, version: String) async throws {
        let existing = (try? await listArchivedApps()) ?? []
        for app in existing
        where app.metadata.bundleID == bundleID && app.metadata.version == version {
            try await deleteArchive(id: app.id)
        }
    }

    /// Returns available disk space at the volume containing `url`, or `nil`.
    private nonisolated func availableDiskSpace(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return UInt64(max(0, bytes))
    }

    /// Recursively sums the file sizes under a directory.
    private static func recursiveSize(of url: URL) -> UInt64 {
        var total: UInt64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
