import SwiftUI

// MARK: - VolumePickerView

/// Start screen grid that displays all mounted volumes as interactive cards.
///
/// Each card shows the volume icon, name, type badge, a usage bar indicating
/// used versus free space, and total/used/free statistics. Clicking a card
/// triggers the `onSelect` callback, which typically starts a scan.
///
/// Network volumes display a "May be slow" warning badge, and external
/// volumes show a visually distinct icon to distinguish them from internal drives.
struct VolumePickerView: View {

    /// All available volumes to display.
    let volumes: [VolumeInfo]

    /// Called when the user selects a volume to scan.
    let onSelect: (VolumeInfo) -> Void

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                volumeGrid
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Select a volume to scan")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Volume Grid

    private var volumeGrid: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 16)
        ], spacing: 16) {
            ForEach(volumes) { volume in
                VolumeCardView(volume: volume) {
                    onSelect(volume)
                }
            }
        }
    }
}

// MARK: - VolumeCardView

/// A single clickable card representing a mounted volume.
///
/// Displays the volume icon, name, type badge, capacity bar, and size breakdown.
/// Hovering highlights the card, and clicking triggers the scan action.
private struct VolumeCardView: View {

    let volume: VolumeInfo
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                usageBar
                statsRow
                warningBadge
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 8 : 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Header Row

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: volumeIcon)
                .font(.title2)
                .foregroundStyle(volumeIconColor)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    typeBadge
                    fsBadge
                    if volume.isReadOnly {
                        readOnlyBadge
                    }
                }
            }

            Spacer()

            if volume.isBoot {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Boot Volume")
            }
        }
    }

    // MARK: - Usage Bar

    private var usageBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let usedWidth = volume.totalCapacity > 0
                ? width * CGFloat(Double(volume.usedSpace) / Double(volume.totalCapacity))
                : 0
            let purgeableWidth = volume.totalCapacity > 0
                ? width * CGFloat(Double(volume.purgeableSpace) / Double(volume.totalCapacity))
                : 0

            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 3)
                    .fill(SpacieColors.progressTrack)

                // Used + purgeable
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(usageBarColor)
                        .frame(width: max(usedWidth - purgeableWidth, 0))

                    if purgeableWidth > 0 {
                        Rectangle()
                            .fill(usageBarColor.opacity(0.4))
                            .frame(width: purgeableWidth)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
        .frame(height: 8)
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack {
            statItem(label: "Used", value: volume.usedSpace.formattedSizeShort)
            Spacer()
            statItem(label: "Free", value: volume.freeSpace.formattedSizeShort)
            Spacer()
            statItem(label: "Total", value: volume.totalCapacity.formattedSizeShort)
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.callout.monospacedDigit().bold())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Warning Badge

    @ViewBuilder
    private var warningBadge: some View {
        if case .network = volume.volumeType {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("Network volume - scan may be slow")
                    .font(.caption2)
            }
            .foregroundStyle(.orange)
        }
    }

    // MARK: - Badges

    private var typeBadge: some View {
        Text(volume.volumeType.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var fsBadge: some View {
        Text(volume.fileSystemType.displayName)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.gray.opacity(0.12))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }

    private var readOnlyBadge: some View {
        HStack(spacing: 2) {
            Image(systemName: "lock.fill")
                .font(.system(size: 8))
            Text("Read Only")
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.red.opacity(0.1))
        .foregroundStyle(.red)
        .clipShape(Capsule())
    }

    // MARK: - Styling Helpers

    private var volumeIcon: String {
        switch volume.volumeType {
        case .internal: "internaldrive.fill"
        case .external: "externaldrive.fill"
        case .network: "network"
        case .disk_image: "opticaldisc.fill"
        }
    }

    private var volumeIconColor: Color {
        switch volume.volumeType {
        case .internal: .blue
        case .external: .green
        case .network: .orange
        case .disk_image: .purple
        }
    }

    private var badgeColor: Color {
        switch volume.volumeType {
        case .internal: .blue
        case .external: .green
        case .network: .orange
        case .disk_image: .purple
        }
    }

    private var usageBarColor: Color {
        let percent = volume.usagePercent
        if percent > 0.9 { return .red }
        if percent > 0.75 { return .orange }
        return .accentColor
    }

    private var cardBackground: some ShapeStyle {
        .background.shadow(.drop(color: .black.opacity(0.04), radius: 2, y: 1))
    }
}
