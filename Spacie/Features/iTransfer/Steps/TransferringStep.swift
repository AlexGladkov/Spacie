import SwiftUI

// Step 6: live transfer progress.

// MARK: - Step 6: Transferring

struct TransferringStepView: View {

    @Bindable var viewModel: iTransferViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Transferring Apps")
                .font(.title2.weight(.semibold))

            if let progress = viewModel.transferProgress {
                ProgressView(value: progress.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 480)

                Text("\(progress.completedCount + progress.failedCount) of \(progress.totalCount) apps")
                    .foregroundStyle(.secondary)

                List(progress.items) { item in
                    TransferItemRow(item: item)
                }
                .listStyle(.bordered)
            } else {
                ProgressView("Starting transfer…")
                    .progressViewStyle(.circular)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button("Cancel") {
                viewModel.cancelTransfer()
                viewModel.step = .result
            }
            .buttonStyle(.bordered)
        }
        .task {
            viewModel.startTransfer()
        }
    }
}

struct TransferItemRow: View {

    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            phaseIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.app.displayName)
                    .font(.callout)
                Text(item.app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.phase == .extracting || item.phase == .installing || item.phase == .archiving {
                ProgressView()
                    .controlSize(.small)
            }
            Text(item.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch item.phase {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .extracting, .archiving, .installing:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
