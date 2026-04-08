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

// MARK: - Install From Archive Sheet

/// Minimal sheet that connects a device and installs a single archived IPA.
private struct InstallFromArchiveSheet: View {

    let app: ArchivedApp
    @Environment(\.dismiss) private var dismiss

    // Device observation
    @State private var device: DeviceInfo?
    @State private var trustState: TrustState = .notTrusted
    @State private var observationTask: Task<Void, Never>?

    // Install state
    @State private var isInstalling = false
    @State private var installProgress: Double = 0
    @State private var installDone = false
    @State private var installError: String?

    private let service: any iMobileDeviceProtocol = iMobileDeviceService()

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.right.and.arrow.left.inward")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(app.displayName)")
                        .font(.headline)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if installDone {
                doneView
            } else if isInstalling {
                installingView
            } else {
                deviceWaitView
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .onAppear { startObservingDevice() }
        .onDisappear { observationTask?.cancel() }
    }

    // MARK: Device wait

    @ViewBuilder
    private var deviceWaitView: some View {
        VStack(spacing: 16) {
            if let device {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.deviceName).font(.headline)
                        Text("iOS \(device.productVersion)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    trustBadge
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                if trustState == .notTrusted {
                    Text("Tap \"Trust\" on the iPhone when prompted.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if trustState == .dialogShown {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for Trust confirmation…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connect the target iPhone via USB…")
                        .foregroundStyle(.secondary)
                }
            }

            if let err = installError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Install") {
                    Task { await beginInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(device == nil || trustState != .trusted || isInstalling)
            }
        }
    }

    @ViewBuilder private var trustBadge: some View {
        switch trustState {
        case .trusted:
            Label("Trusted", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.medium)).foregroundStyle(.green)
        case .dialogShown:
            Label("Waiting…", systemImage: "clock")
                .font(.caption).foregroundStyle(.orange)
        case .notTrusted:
            Label("Not Trusted", systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.red)
        }
    }

    // MARK: Installing

    private var installingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: installProgress > 0 ? installProgress : nil)
                .progressViewStyle(.linear)
            Text(installProgress > 0
                 ? "Installing… \(Int(installProgress * 100))%"
                 : "Installing…")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: Done

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Installed on \(device?.deviceName ?? "iPhone")")
                .font(.headline)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Logic

    private func startObservingDevice() {
        observationTask = Task {
            for await event in service.observeDevices(pollingInterval: 2.0) {
                await handleEvent(event)
                if Task.isCancelled { break }
            }
        }
    }

    @MainActor
    private func handleEvent(_ event: DeviceEvent) {
        switch event {
        case .connected(let d):
            if device == nil {
                device = d
                trustState = .notTrusted
                Task {
                    trustState = await service.validateTrust(udid: d.udid)
                }
            }
        case .disconnected(let udid):
            if device?.udid == udid { device = nil; trustState = .notTrusted }
        case .trustStateChanged(let udid, let state):
            if device?.udid == udid { trustState = state }
        case .error:
            break
        }
    }

    @MainActor
    private func beginInstall() async {
        guard let udid = device?.udid else { return }
        installError = nil
        isInstalling = true
        installProgress = 0
        do {
            try await service.installIPA(udid: udid, ipaPath: app.ipaURL) { p in
                Task { @MainActor in installProgress = p }
            }
            installDone = true
            observationTask?.cancel()
        } catch {
            installError = error.localizedDescription
        }
        isInstalling = false
    }
}
