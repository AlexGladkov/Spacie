import SwiftUI
import UniformTypeIdentifiers

// MARK: - AppArchiveView

/// Displays the local IPA archive library.
///
/// Lists all IPAs that have been extracted from iPhones and stored locally.
/// Supports selection-based batch delete, single-entry Finder reveal,
/// and IPA export via an `NSSavePanel`.
///
/// Intended to be presented as a sheet from ``iTransferView`` or navigated
/// to from the result step of the transfer wizard.
struct AppArchiveView: View {

    @State private var viewModel = AppArchiveViewModel()
    @State private var showDeleteConfirmation = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && viewModel.archivedApps.isEmpty {
                loadingView
            } else if viewModel.archivedApps.isEmpty {
                emptyView
            } else {
                archiveTable
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle("IPA Archive")
        .toolbar { toolbarContent }
        .task { await viewModel.load() }
        .sheet(item: $viewModel.appToInstall) { app in
            InstallFromArchiveSheet(app: app)
                .frame(minWidth: 400, minHeight: 280)
        }
        .confirmationDialog(
            "Delete \(viewModel.selectionCount) archive\(viewModel.selectionCount == 1 ? "" : "s")?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove the selected IPA files from disk.")
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let msg = viewModel.errorMessage {
                Text(msg)
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ProgressView("Loading archive…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "archivebox")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("No Archived Apps")
                .font(.title3.bold())
            Text("Apps extracted from iPhones will appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Table

    private var archiveTable: some View {
        Table(viewModel.archivedApps, selection: $viewModel.selectedIDs) {
            TableColumn("App") { app in
                HStack(spacing: 10) {
                    appIconView(data: app.iconData)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.displayName)
                            .font(.callout.bold())
                            .lineLimit(1)
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .width(min: 180)

            TableColumn("Version") { app in
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.metadata.shortVersion)
                    Text("(\(app.metadata.version))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 80, max: 120)

            TableColumn("Size") { app in
                Text(Self.byteFormatter.string(fromByteCount: Int64(app.metadata.ipaSize)))
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Archived") { app in
                Text(app.metadata.archivedAt, format: .dateTime.day().month().year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 130)

            TableColumn("Source Device") { app in
                Text(app.metadata.sourceDeviceName ?? "—")
                    .foregroundStyle(app.metadata.sourceDeviceName != nil ? .primary : .secondary)
            }
            .width(min: 100, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first,
               let app = viewModel.archivedApps.first(where: { $0.id == id }) {
                Button {
                    viewModel.appToInstall = app
                } label: {
                    Label("Install on iPhone…", systemImage: "iphone.and.arrow.right.and.arrow.left.inward")
                }

                Divider()

                Button {
                    viewModel.revealInFinder(app)
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }

                Button {
                    viewModel.exportIPA(app)
                } label: {
                    Label("Export IPA…", systemImage: "square.and.arrow.up")
                }

                Divider()

                Button(role: .destructive) {
                    Task { await viewModel.delete(id: id) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }

            } else if ids.count > 1 {
                Button(role: .destructive) {
                    viewModel.selectedIDs = ids
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete \(ids.count) Archives…", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - App Icon

    @ViewBuilder
    private func appIconView(data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            if !viewModel.archivedApps.isEmpty {
                Text(
                    "\(viewModel.archivedApps.count) app\(viewModel.archivedApps.count == 1 ? "" : "s") · " +
                    Self.byteFormatter.string(fromByteCount: Int64(viewModel.totalSize))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .disabled(viewModel.isLoading)
        }

        ToolbarItem(placement: .destructiveAction) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Selected", systemImage: "trash")
            }
            .help("Delete selected archives")
            .disabled(!viewModel.hasSelection || viewModel.isLoading)
        }
    }
}
