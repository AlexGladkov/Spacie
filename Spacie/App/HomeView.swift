import SwiftUI

// MARK: - HomeFeature

/// Top-level features accessible from the home screen.
enum HomeFeature {
    case diskAnalyzer
    case iosTransfer
}

// MARK: - HomeView

/// Root view that presents a tile-based launcher for all Spacie features.
///
/// Clicking a tile navigates to the corresponding feature. The iOS Transfer
/// tile is hidden in App Store builds (where the `DIRECT` flag is absent).
struct HomeView: View {

    @Environment(VolumeManager.self) private var volumeManager
    @Environment(PermissionManager.self) private var permissionManager

    @State private var selectedFeature: HomeFeature?

    var body: some View {
        Group {
            if let feature = selectedFeature {
                featureView(for: feature)
            } else {
                launcherView
            }
        }
        .frame(minWidth: 800, minHeight: 500)
    }

    // MARK: - Launcher

    private var launcherView: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text("Spacie")
                        .font(.largeTitle.weight(.bold))
                }
                Text("Select a feature to get started")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)

            // Feature tiles
            HStack(alignment: .top, spacing: 20) {
                FeatureTile(
                    icon: "externaldrive.fill.badge.icloud",
                    iconColor: .accentColor,
                    title: "Disk Analyzer",
                    description: "Visualize what's taking up space on your Mac. Scan volumes with Sunburst and Treemap views.",
                    badge: nil
                ) {
                    selectedFeature = .diskAnalyzer
                }

                #if DIRECT
                FeatureTile(
                    icon: "iphone.and.arrow.right.and.arrow.left.inward",
                    iconColor: .orange,
                    title: "iOS Transfer",
                    description: "Transfer apps between two iPhones. Save IPAs of apps removed from the App Store.",
                    badge: "USB"
                ) {
                    selectedFeature = .iosTransfer
                }
                #endif
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 680)
            .padding(.top, 36)
            .padding(.horizontal, 40)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Spacie")
    }

    // MARK: - Feature Routing

    @ViewBuilder
    private func featureView(for feature: HomeFeature) -> some View {
        switch feature {
        case .diskAnalyzer:
            ContentView(onDismiss: { selectedFeature = nil })
                .environment(volumeManager)
                .environment(permissionManager)

        #if DIRECT
        case .iosTransfer:
            iTransferView(onDismiss: { selectedFeature = nil })
                .environment(volumeManager)
                .environment(permissionManager)
        #endif
        }
    }
}

// MARK: - FeatureTile

private struct FeatureTile: View {

    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let badge: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 36))
                        .foregroundStyle(iconColor)
                        .frame(width: 44, height: 44)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.6), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack {
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(iconColor.opacity(isHovered ? 1 : 0.5))
                }
            }
            .padding(22)
            .frame(width: 260, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.20 : 0.10), radius: isHovered ? 14 : 7, y: isHovered ? 4 : 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isHovered ? iconColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
