import SwiftUI

// MARK: - iTransferView

/// Root view for the iOS App Transfer wizard.
///
/// Renders the appropriate step view based on ``iTransferViewModel/step``.
/// Navigation between steps is driven exclusively by the view model —
/// the view never advances the step directly.
struct iTransferView: View {

    @State private var viewModel = iTransferViewModel()
    @State private var showArchiveLibrary = false
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            iTransferStepIndicator(currentStep: viewModel.step)
                .padding(.horizontal, 32)
                .padding(.top, 20)

            Divider()
                .padding(.top, 12)

            // Active step
            Group {
                switch viewModel.step {
                case .dependencyCheck:
                    DependencyCheckStepView(viewModel: viewModel)
                case .connectSource:
                    ConnectDeviceStepView(
                        title: "Connect Source iPhone",
                        subtitle: "Connect the iPhone you want to transfer apps FROM.",
                        device: viewModel.sourceDevice,
                        trustState: viewModel.sourceTrustState,
                        isWaiting: viewModel.isWaitingForSource,
                        onStart: { viewModel.startSourceDeviceObservation() }
                    )
                case .selectApps:
                    SelectAppsStepView(viewModel: viewModel)
                case .chooseAction:
                    ChooseActionStepView(viewModel: viewModel)
                case .connectDestination:
                    ConnectDeviceStepView(
                        title: "Connect Destination iPhone",
                        subtitle: "Connect the iPhone you want to transfer apps TO.",
                        device: viewModel.destinationDevice,
                        trustState: viewModel.destinationTrustState,
                        isWaiting: viewModel.isWaitingForDestination,
                        onStart: { viewModel.startDestinationDeviceObservation() }
                    )
                case .transferring:
                    TransferringStepView(viewModel: viewModel)
                case .result:
                    ResultStepView(
                        viewModel: viewModel,
                        onDismiss: {
                            viewModel.reset()
                            onDismiss?()
                        },
                        onShowArchive: {
                            showArchiveLibrary = true
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .navigationTitle("iOS Transfer")
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.stopDeviceObservation()
                        onDismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showArchiveLibrary = true
                } label: {
                    Label("Archive Library", systemImage: "archivebox")
                }
                .help("Browse archived IPA files")
            }
        }
        .sheet(isPresented: $showArchiveLibrary) {
            AppArchiveView()
                .frame(minWidth: 700, minHeight: 420)
        }
        .task {
            await viewModel.checkDependencies()
        }
        .onDisappear {
            viewModel.stopDeviceObservation()
            viewModel.cancelTransfer()
        }
    }
}
