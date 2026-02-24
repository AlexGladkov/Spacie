import SwiftUI

// MARK: - YellowPhaseOverview

/// Overview screen shown during Yellow phase (Phase 1 complete, Phase 2 in progress).
///
/// Displays a donut chart of top directories by entry count on the left
/// and scan statistics on the right. Replaces the regular sunburst/treemap
/// which looks poor with approximate entry-count data.
struct YellowPhaseOverview: View {
    let tree: FileTree
    let scanState: ScanState
    @Bindable var state: VisualizationState

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Left: Donut chart
            donutChart
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)

            Divider()

            // Right: Statistics
            statisticsPanel
                .frame(width: 320)
                .frame(maxHeight: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Donut Chart

    private var donutChart: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let outerRadius = size / 2 * 0.85
            let innerRadius = outerRadius * 0.55
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let slices = buildSlices()

            ZStack {
                // Donut segments
                ForEach(slices) { slice in
                    DonutSlice(
                        center: center,
                        innerRadius: innerRadius,
                        outerRadius: outerRadius,
                        startAngle: slice.startAngle,
                        endAngle: slice.endAngle
                    )
                    .fill(slice.color)
                    .overlay {
                        DonutSlice(
                            center: center,
                            innerRadius: innerRadius,
                            outerRadius: outerRadius,
                            startAngle: slice.startAngle,
                            endAngle: slice.endAngle
                        )
                        .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                    }
                }

                // Center label
                VStack(spacing: 4) {
                    let rootEntryCount = tree.entryCount(of: state.currentRootIndex)
                    Text(rootEntryCount.formatted())
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("items")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("(approximate)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .position(center)
            }
        }
    }

    // MARK: - Statistics Panel

    private var statisticsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.yellow)
                            .frame(width: 8, height: 8)
                        Text("Approximate Data")
                            .font(.headline)
                    }
                    Text("Deep scan in progress. Sizes will update gradually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Scan stats
                scanStatsSection

                Divider()

                // Top directories
                topDirectoriesSection

                Spacer()
            }
            .padding(20)
        }
    }

    private var scanStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan Summary")
                .font(.subheadline.weight(.semibold))

            let rootInfo = tree.nodeInfo(at: state.currentRootIndex)

            StatRow(label: "Root", value: rootInfo.name)
            StatRow(label: "Directories", value: tree.nodeCount.formatted())

            if let totalEntries = totalEntryCount {
                StatRow(label: "Estimated files", value: totalEntries.formatted())
            }

            if case .scanning(let progress) = scanState {
                StatRow(label: "Elapsed", value: progress.elapsedTime.formattedDuration)

                if progress.phase == .yellow {
                    StatRow(
                        label: "Deep scan",
                        value: "\(progress.deepScanDirsCompleted)/\(progress.deepScanDirsTotal) dirs"
                    )
                }

                if progress.skippedDirectories > 0 {
                    StatRow(
                        label: "Skipped",
                        value: "\(progress.skippedDirectories) directories",
                        valueColor: .orange
                    )
                }
            }

            if case .completed(let stats) = scanState {
                StatRow(label: "Duration", value: stats.scanDuration.formattedDuration)
                StatRow(label: "Files", value: stats.totalFiles.formattedCount)

                if stats.skippedDirectories > 0 {
                    StatRow(
                        label: "Skipped",
                        value: "\(stats.skippedDirectories) directories",
                        valueColor: .orange
                    )
                }
            }
        }
    }

    private var topDirectoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Directories")
                .font(.subheadline.weight(.semibold))

            let slices = buildSlices().filter { !$0.isOther }

            ForEach(slices.prefix(10)) { slice in
                HStack(spacing: 8) {
                    Circle()
                        .fill(slice.color)
                        .frame(width: 10, height: 10)

                    Text(slice.name)
                        .font(.system(size: 12))
                        .lineLimit(1)

                    Spacer()

                    Text("\(slice.percentage, specifier: "%.1f")%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text("\(slice.entryCount.formatted()) items")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 80, alignment: .trailing)
                }
            }

            // "Other" entry if present
            if let other = buildSlices().first(where: { $0.isOther }) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(other.color)
                        .frame(width: 10, height: 10)

                    Text("Other")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(other.percentage, specifier: "%.1f")%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Slice Data

    private struct SliceData: Identifiable {
        let id: UInt32
        let name: String
        let entryCount: UInt32
        let percentage: Double
        let startAngle: Double
        let endAngle: Double
        let color: Color
        let isOther: Bool
    }

    private var totalEntryCount: UInt32? {
        let count = tree.entryCount(of: state.currentRootIndex)
        return count > 0 ? count : nil
    }

    private func buildSlices() -> [SliceData] {
        let rootIndex = state.currentRootIndex
        let children = tree.children(of: rootIndex)
        guard !children.isEmpty else { return [] }

        let totalCount = tree.entryCount(of: rootIndex)
        guard totalCount > 0 else { return [] }

        // Sort by entry count descending
        let sorted = children
            .map { (index: $0, count: tree.entryCount(of: $0)) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }

        let colorPalette: [Color] = [
            Color(red: 0.29, green: 0.56, blue: 0.85), // Blue
            Color(red: 0.10, green: 0.74, blue: 0.61), // Teal
            Color(red: 0.90, green: 0.49, blue: 0.13), // Orange
            Color(red: 0.61, green: 0.35, blue: 0.71), // Purple
            Color(red: 0.15, green: 0.68, blue: 0.38), // Green
            Color(red: 0.91, green: 0.30, blue: 0.24), // Red
            Color(red: 0.95, green: 0.77, blue: 0.06), // Yellow
            Color(red: 0.55, green: 0.27, blue: 0.07), // Brown
            Color(red: 0.35, green: 0.71, blue: 0.85), // Sky
            Color(red: 0.74, green: 0.24, blue: 0.58), // Magenta
        ]

        var slices: [SliceData] = []
        var angle: Double = -.pi / 2 // Start from top
        var otherCount: UInt32 = 0

        let minPercent: Double = 0.02 // 2% threshold for "Other"

        for (i, item) in sorted.enumerated() {
            let percentage = Double(item.count) / Double(totalCount)
            if percentage < minPercent || i >= 10 {
                otherCount &+= item.count
                continue
            }

            let sweep = percentage * 2 * .pi
            let name = tree.name(of: item.index)
            let color = colorPalette[i % colorPalette.count]

            slices.append(SliceData(
                id: item.index,
                name: name,
                entryCount: item.count,
                percentage: percentage * 100,
                startAngle: angle,
                endAngle: angle + sweep,
                color: color,
                isOther: false
            ))
            angle += sweep
        }

        // Add "Other" slice
        if otherCount > 0 {
            let percentage = Double(otherCount) / Double(totalCount)
            let sweep = percentage * 2 * .pi
            slices.append(SliceData(
                id: UInt32.max,
                name: "Other",
                entryCount: otherCount,
                percentage: percentage * 100,
                startAngle: angle,
                endAngle: angle + sweep,
                color: Color(red: 0.74, green: 0.76, blue: 0.78),
                isOther: true
            ))
        }

        return slices
    }
}

// MARK: - Donut Slice Shape

private struct DonutSlice: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = Angle(radians: startAngle)
        let end = Angle(radians: endAngle)

        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()

        return path
    }
}

// MARK: - Stat Row

private struct StatRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}
