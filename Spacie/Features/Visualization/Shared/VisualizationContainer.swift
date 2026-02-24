import SwiftUI

// MARK: - VisualizationContainer

/// Container view that hosts either the sunburst or treemap visualization
/// based on the current mode selection. Provides common chrome including
/// the breadcrumb navigation bar and an info bar overlay at the bottom.
///
/// Handles empty state (no scan data), loading state (scan in progress with
/// partial data), and smooth animated transitions between visualization modes.
struct VisualizationContainer: View {
    /// The file tree data source. `nil` when no scan has been performed.
    let tree: FileTree?

    /// The current scan state for showing progress and stats.
    let scanState: ScanState

    /// Binding to the current visualization mode (sunburst vs treemap).
    @Binding var visualizationMode: VisualizationMode

    /// Observable navigation and interaction state.
    @Bindable var state: VisualizationState

    /// Size display mode (logical vs physical).
    @Binding var sizeMode: SizeMode

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if let tree {
                // Breadcrumb bar
                BreadcrumbView(tree: tree, state: state)
                    .zIndex(1)

                Divider()

                // Visualization area
                ZStack {
                    visualizationContent(tree: tree)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))

                    // Scanning overlay (partial data indicator)
                    if case .scanning(let progress) = scanState {
                        scanningOverlay(progress: progress)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                Divider()

                // Info bar
                infoBar(tree: tree)
            } else {
                emptyStateView
            }
        }
        .animation(
            .easeInOut(duration: VisualizationConstants.drillDownAnimationDuration),
            value: visualizationMode
        )
    }

    // MARK: - Visualization Content

    /// Renders the appropriate visualization based on the current mode and phase.
    ///
    /// During Yellow phase (approximate data), shows a dedicated overview with
    /// a donut chart and statistics instead of the regular sunburst/treemap.
    @ViewBuilder
    private func visualizationContent(tree: FileTree) -> some View {
        if state.useEntryCount {
            // Yellow phase: show pie chart + stats overview
            YellowPhaseOverview(tree: tree, scanState: scanState, state: state)
        } else {
            switch visualizationMode {
            case .sunburst:
                SunburstView(tree: tree, state: state)
                    .id("sunburst-\(state.currentRootIndex)")

            case .treemap:
                TreemapView(tree: tree, state: state)
                    .id("treemap-\(state.currentRootIndex)")
            }
        }
    }

    // MARK: - Empty State

    /// Shown when no file tree data is available (before first scan).
    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Scan Data")
                .font(.title2)
                .fontWeight(.medium)

            Text("Select a volume and start a scan to visualize disk usage.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if case .scanning(let progress) = scanState {
                // Show scanning progress even before tree is available.
                VStack(spacing: 8) {
                    ProgressView(value: progress.estimatedProgress ?? 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)

                    Text("Scanning: \(progress.filesScanned.formattedCount) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Scanning Overlay

    /// Semi-transparent overlay shown during an active scan with live data.
    @ViewBuilder
    private func scanningOverlay(progress: ScanProgress) -> some View {
        VStack {
            Spacer()

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.phase == .yellow ? "Deep scanning..." : "Scanning...")
                        .font(.system(size: 11, weight: .medium))

                    Text(scanProgressText(progress))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let coverage = progress.coveragePercent {
                    Text("Coverage: \(Int(coverage * 100))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if progress.phase == .yellow, let deepProgress = progress.deepScanProgress {
                    Text("\(Int(deepProgress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if let percent = progress.estimatedProgress {
                    Text("\(Int(percent * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .allowsHitTesting(false)
    }

    /// Formats the scanning progress text with file count and current path.
    private func scanProgressText(_ progress: ScanProgress) -> String {
        if progress.phase == .yellow {
            let completed = progress.deepScanDirsCompleted
            let total = progress.deepScanDirsTotal
            let path = abbreviatedPath(progress.currentPath)
            if total > 0 {
                return "\(completed)/\(total) directories - \(path)"
            }
            return "Deep scan in progress - \(path)"
        }
        let fileCount = progress.filesScanned.formattedCount
        let size = progress.totalSizeScanned(for: sizeMode).formattedSizeShort
        let path = abbreviatedPath(progress.currentPath)
        return "\(fileCount) files, \(size) - \(path)"
    }

    /// Abbreviates a long file path for display by keeping the last two components.
    private func abbreviatedPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count <= 3 {
            return path
        }
        let last = components.suffix(2).joined(separator: "/")
        return ".../\(last)"
    }

    // MARK: - Info Bar

    /// Bottom info bar showing file count, total size, and scan time.
    @ViewBuilder
    private func infoBar(tree: FileTree) -> some View {
        HStack(spacing: 16) {
            // File count
            infoItem(
                icon: "doc.on.doc",
                value: "\(tree.nodeCount.formatted()) items"
            )

            Divider()
                .frame(height: 12)

            // Total size or entry count of current root
            if state.useEntryCount {
                let entryCount = tree.entryCount(of: state.currentRootIndex)
                infoItem(
                    icon: "number",
                    value: "\(entryCount.formatted()) items (approximate)"
                )
            } else {
                let rootSize = tree.size(of: state.currentRootIndex, mode: state.sizeMode)
                infoItem(
                    icon: "internaldrive",
                    value: rootSize.formattedSize
                )

                Divider()
                    .frame(height: 12)

                // Size mode indicator
                infoItem(
                    icon: sizeMode == .logical ? "ruler" : "cube",
                    value: sizeMode.displayName
                )
            }

            Spacer()

            // Scan stats (if completed)
            if case .completed(let stats) = scanState {
                infoItem(
                    icon: "clock",
                    value: "Scanned in \(stats.scanDuration.formattedDuration)"
                )

                if stats.restrictedDirectories > 0 {
                    Divider()
                        .frame(height: 12)

                    Label {
                        Text("\(stats.restrictedDirectories) restricted")
                            .font(.system(size: 11))
                            .foregroundStyle(SpacieColors.warningForeground)
                    } icon: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SpacieColors.warningForeground)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    /// A small icon + value pair for the info bar.
    @ViewBuilder
    private func infoItem(icon: String, value: String) -> some View {
        Label {
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Container - Empty State") {
    VisualizationContainer(
        tree: nil,
        scanState: .idle,
        visualizationMode: .constant(.sunburst),
        state: VisualizationState(rootIndex: 0),
        sizeMode: .constant(.logical)
    )
    .frame(width: 800, height: 600)
}
#endif
