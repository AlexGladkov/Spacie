import SwiftUI

// Step 7: post-transfer summary.

// MARK: - Step 7: Result

struct ResultStepView: View {

    let viewModel: iTransferViewModel
    let onDismiss: () -> Void
    let onShowArchive: () -> Void

    private var archiveDir: URL {
        viewModel.archiveDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spacie/Archives", isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if let result = viewModel.transferResult {
                let allOK = result.failureCount == 0
                Image(systemName: allOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(allOK ? .green : .orange)

                Text(allOK ? "Transfer Complete" : "Transfer Finished with Errors")
                    .font(.title2.weight(.semibold))

                Text("\(result.successCount) succeeded · \(result.failureCount) failed")
                    .foregroundStyle(.secondary)

                if !result.items.isEmpty {
                    List(result.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.app.displayName).font(.callout)
                                if let error = item.error {
                                    Text(error.localizedDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(maxHeight: 180)
                }

                // Show where files were saved
                if result.successCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(archiveDir.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show") {
                            NSWorkspace.shared.open(archiveDir)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 440)
                }

            } else if let error = viewModel.lastError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)
                Text("Transfer Failed")
                    .font(.title2.weight(.semibold))
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Transfer More") {
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
                Button {
                    onShowArchive()
                } label: {
                    Label("View Archive", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }
}
