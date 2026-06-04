import SwiftUI

// Steps 2 & 5: connect source / destination device.

// MARK: - Steps 2 & 5: Connect Device

struct ConnectDeviceStepView: View {

    let title: String
    let subtitle: String
    let device: DeviceInfo?
    let trustState: TrustState
    let isWaiting: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "iphone.and.arrow.right.and.arrow.left.inward")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let device {
                deviceCard(device: device)
            } else if isWaiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for device…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Start Waiting for Device") {
                    onStart()
                }
                .buttonStyle(.borderedProminent)
            }

            if trustState == .notTrusted, device != nil {
                trustInstructions
            } else if trustState == .dialogShown {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to tap \"Trust\" on the iPhone…")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .onAppear { if !isWaiting { onStart() } }
    }

    private func deviceCard(device: DeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.headline)
                Text("\(device.productType) · iOS \(device.productVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trustBadge
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var trustBadge: some View {
        switch trustState {
        case .trusted:
            Label("Trusted", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .dialogShown:
            Label("Waiting…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notTrusted:
            Label("Not Trusted", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var trustInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trust Required", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
            Text("1. Unlock your iPhone.\n2. Tap **Trust** when the \"Trust This Computer?\" dialog appears.\n3. Enter your iPhone passcode if prompted.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }
}
