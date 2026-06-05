import SwiftUI

// MARK: - InstallFromArchiveSheet

/// Minimal sheet that connects an iPhone and installs a single archived IPA.
///
/// Presented from ``AppArchiveView`` via `.sheet(item:)`. Logic lives in
/// ``InstallFromArchiveViewModel`` so it is testable and previewable.
struct InstallFromArchiveSheet: View {

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: InstallFromArchiveViewModel

    init(app: ArchivedApp) {
        _viewModel = State(initialValue: InstallFromArchiveViewModel(app: app))
    }

    /// Designated initializer used by previews / tests to inject a mock service.
    init(viewModel: InstallFromArchiveViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.right.and.arrow.left.inward")
                    .font(.title)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install \(viewModel.app.displayName)")
                        .font(.headline)
                    Text(viewModel.app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if viewModel.installDone {
                doneView
            } else if viewModel.isInstalling {
                installingView
            } else {
                deviceWaitView
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .onAppear { viewModel.startObservingDevice() }
        .onDisappear { viewModel.stopObservingDevice() }
    }

    // MARK: - Device wait

    @ViewBuilder
    private var deviceWaitView: some View {
        VStack(spacing: 16) {
            if let device = viewModel.device {
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

                if viewModel.trustState == .notTrusted {
                    Text("Tap \"Trust\" on the iPhone when prompted.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if viewModel.trustState == .dialogShown {
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

            if let err = viewModel.installError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Install") {
                    Task { await viewModel.beginInstall() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canInstall)
            }
        }
    }

    @ViewBuilder private var trustBadge: some View {
        switch viewModel.trustState {
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

    // MARK: - Installing

    private var installingView: some View {
        VStack(spacing: 12) {
            ProgressView(value: viewModel.installProgress > 0 ? viewModel.installProgress : nil)
                .progressViewStyle(.linear)
            Text(viewModel.installProgress > 0
                 ? "Installing… \(Int(viewModel.installProgress * 100))%"
                 : "Installing…")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: - Done

    private var doneView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Installed on \(viewModel.device?.deviceName ?? "iPhone")")
                .font(.headline)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Install — waiting for device") {
    let sample = ArchivedApp.previewSample
    let vm = InstallFromArchiveViewModel(
        app: sample,
        service: MockiMobileDeviceService()
    )
    return InstallFromArchiveSheet(viewModel: vm)
        .frame(width: 440, height: 320)
}

#Preview("Install — done") {
    let sample = ArchivedApp.previewSample
    let mock = MockiMobileDeviceService.withSampleData()
    let vm = InstallFromArchiveViewModel(app: sample, service: mock)
    return InstallFromArchiveSheet(viewModel: vm)
        .frame(width: 440, height: 320)
        .onAppear {
            // Simulate the completed state for the preview.
            Task { @MainActor in
                // No way to set private state from outside — accept this as
                // an empty-device preview. A snapshot test can drive deeper
                // states via the protocol.
            }
        }
}
#endif
