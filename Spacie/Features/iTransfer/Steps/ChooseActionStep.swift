import SwiftUI

// Step 4: archive only vs archive + install.

// MARK: - Step 4: Choose Action

struct ChooseActionStepView: View {

    @Bindable var viewModel: iTransferViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("What would you like to do?")
                .font(.title2.weight(.semibold))

            HStack(spacing: 16) {
                ActionCard(
                    icon: "tray.and.arrow.down.fill",
                    title: "Archive Only",
                    description: "Save \(viewModel.selectedAppsCount) IPA file(s) to a local folder on this Mac.",
                    isSelected: viewModel.archiveOnly
                ) {
                    viewModel.chooseArchiveOnly()
                }

                ActionCard(
                    icon: "iphone.and.arrow.right.and.arrow.left.inward",
                    title: "Archive + Install",
                    description: "Save IPA(s) locally AND install them on another iPhone.",
                    isSelected: !viewModel.archiveOnly
                ) {
                    viewModel.chooseArchiveAndInstall()
                }
            }
            .frame(maxWidth: 600)

            // Archive directory picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Archive Location")
                    .font(.subheadline.weight(.medium))
                HStack {
                    Text(viewModel.archiveDir?.path ?? "Default: ~/Library/Application Support/Spacie/Archives")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        viewModel.selectArchiveDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 500)

            // Surface archiveDir validation errors that
            // `proceedFromChooseAction` writes to `lastError`. Without this,
            // a Continue tap on an unwritable archive folder appeared to
            // silently no-op — user couldn't tell what went wrong.
            if let error = viewModel.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            Button("Continue") {
                viewModel.proceedFromChooseAction()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ActionCard: View {

    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(isSelected ? 0.15 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
