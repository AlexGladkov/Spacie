import SwiftUI

// MARK: - AppArchiveViewModel

/// View model for the IPA Archive Library screen.
///
/// Loads archived apps from ``AppArchiveProtocol``, supports selection-based
/// batch delete, single-entry reveal/export, and shows aggregate storage usage.
///
/// Follows the same `@MainActor @Observable` pattern used by
/// ``iTransferViewModel`` and ``AppViewModel``.
@MainActor
@Observable
final class AppArchiveViewModel {

    // MARK: - State

    /// Archived apps sorted by archival date, newest first.
    var archivedApps: [ArchivedApp] = []

    /// `true` while an async load or delete is in flight.
    var isLoading = false

    /// Human-readable error from the last failed operation.
    var errorMessage: String?

    /// Total bytes used by all archived IPAs.
    var totalSize: UInt64 = 0

    /// IDs of rows selected in the archive table.
    var selectedIDs: Set<String> = []

    // MARK: - Dependencies

    private let service: any AppArchiveProtocol

    // MARK: - Init

    init(service: any AppArchiveProtocol = AppArchiveService()) {
        self.service = service
    }

    // MARK: - Load

    /// Reloads the full archive list and refreshes ``totalSize``.
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let apps = service.listArchivedApps()
            async let size = service.totalArchiveSize()
            archivedApps = try await apps
            totalSize = try await size
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Delete

    /// Deletes a single archive entry and refreshes ``totalSize``.
    func delete(id: String) async {
        do {
            try await service.deleteArchive(id: id)
            archivedApps.removeAll { $0.id == id }
            selectedIDs.remove(id)
            totalSize = (try? await service.totalArchiveSize()) ?? 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes all currently selected archive entries.
    func deleteSelected() async {
        let ids = selectedIDs
        for id in ids {
            await delete(id: id)
        }
    }

    // MARK: - Reveal / Export

    /// Reveals the IPA file for `app` in Finder.
    func revealInFinder(_ app: ArchivedApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.ipaURL])
    }

    /// Presents an `NSSavePanel` and copies the IPA to the chosen location.
    func exportIPA(_ app: ArchivedApp) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = app.ipaURL.lastPathComponent
        panel.allowedContentTypes = [.init(exportedAs: "com.apple.itunes.ipa")]
        panel.message = "Choose where to export \(app.displayName).ipa"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: app.ipaURL, to: dest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Install

    /// The app currently queued for installation (drives the install sheet).
    var appToInstall: ArchivedApp?

    // MARK: - Computed

    var hasSelection: Bool { !selectedIDs.isEmpty }
    var selectionCount: Int { selectedIDs.count }
}
