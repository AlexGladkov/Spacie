import SwiftUI

// Step 3: pick which apps to transfer.

// MARK: - Step 3: Select Apps

struct SelectAppsStepView: View {

    @Bindable var viewModel: iTransferViewModel
    @State private var sortOrder = [KeyPathComparator(\AppInfo.displayName)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Select Apps to Transfer")
                    .font(.title2.weight(.semibold))
                Spacer()
                if viewModel.isLoadingApps {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(viewModel.selectedBundleIDs.count) of \(viewModel.availableApps.count) selected")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("All") { viewModel.selectAllApps() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("None") { viewModel.deselectAllApps() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if viewModel.isLoadingApps {
                Spacer()
                ProgressView("Loading app list…")
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.availableApps.isEmpty {
                if let error = viewModel.lastError {
                    ContentUnavailableView(
                        "Failed to Load Apps",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    ContentUnavailableView(
                        "No User Apps Found",
                        systemImage: "tray",
                        description: Text("No user-installed apps were found on this device.")
                    )
                }
            } else {
                Table(viewModel.availableApps, sortOrder: $sortOrder) {
                    TableColumn("") { app in
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedBundleIDs.contains(app.bundleID) },
                            set: { _ in viewModel.toggleAppSelection(app.bundleID) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    }
                    .width(28)

                    TableColumn("App", value: \.displayName) { app in
                        HStack(spacing: 8) {
                            Image(systemName: "app.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                    .font(.callout)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    TableColumn("Version", value: \.shortVersion) { app in
                        Text(app.shortVersion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .width(80)

                    TableColumn("Size") { app in
                        Text(app.ipaSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .onChange(of: sortOrder) {
                    viewModel.availableApps.sort(using: sortOrder)
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    viewModel.proceedFromSelectApps()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canProceedFromSelectApps)
            }
        }
    }
}
