import SwiftUI

// MARK: - InfoBarView

/// A compact, single-line status bar displayed at the bottom of the main window.
///
/// When a scan is complete, shows file count, used/free space, and time since the
/// last scan. During an active scan, shows live progress with file count, size,
/// and scan rate. When FSEvents have detected changes since the last scan, displays
/// a "Data may be outdated" warning with a refresh button.
struct InfoBarView: View {

    let viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.scanState {
        case .scanning(let progress):
            scanningContent(progress: progress)

        case .completed(let stats):
            completedContent(stats: stats)

        case .idle:
            idleContent

        case .cancelled:
            cancelledContent

        case .error(let message):
            errorContent(message: message)
        }
    }

    // MARK: - Scanning State

    private func scanningContent(progress: ScanProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.mini)

            separator

            statLabel(icon: "doc", text: progress.filesScanned.formattedCount + " files")
            separator
            statLabel(icon: "internaldrive", text: progress.totalSizeScanned.formattedSize)
            separator
            statLabel(icon: "speedometer", text: String(format: "%.0f files/s", progress.filesPerSecond))
            separator

            Text(progress.currentPath)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 300, alignment: .leading)

            Spacer()
        }
    }

    // MARK: - Completed State

    private func completedContent(stats: ScanStats) -> some View {
        HStack(spacing: 12) {
            statLabel(icon: "doc", text: stats.totalFiles.formattedCount + " files")
            separator

            if let volume = viewModel.volume {
                statLabel(icon: "internaldrive", text: volume.usedSpace.formattedSize + " used")
                separator
                statLabel(icon: "circle.dashed", text: volume.freeSpace.formattedSize + " free")
                separator
            }

            scanTimingLabel

            Spacer()

            if viewModel.dataIsStale {
                staleDataWarning
            }
        }
    }

    // MARK: - Idle State

    private var idleContent: some View {
        HStack {
            Text("Ready to scan")
            Spacer()
        }
    }

    // MARK: - Cancelled State

    private var cancelledContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.orange)
            Text("Scan cancelled")
            Spacer()
        }
    }

    // MARK: - Error State

    private func errorContent(message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(message)
                .lineLimit(1)
            Spacer()
        }
    }

    // MARK: - Scan Timing

    private var scanTimingLabel: some View {
        Group {
            if let lastScan = viewModel.lastScanDate {
                let elapsed = Date().timeIntervalSince(lastScan)
                statLabel(icon: "clock", text: "Scan: \(relativeTimeString(elapsed))")
            }
        }
    }

    // MARK: - Stale Data Warning

    private var staleDataWarning: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Data may be outdated")
                .foregroundStyle(.orange)

            Button {
                Task { await viewModel.rescan() }
            } label: {
                Text("Refresh")
                    .font(.caption.bold())
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    // MARK: - Components

    private func statLabel(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
        }
    }

    private var separator: some View {
        Text("|")
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 2)
    }

    // MARK: - Formatting

    /// Formats a time interval into a human-readable relative string.
    private func relativeTimeString(_ interval: TimeInterval) -> String {
        if interval < 5 {
            return "just now"
        } else if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3600 {
            let minutes = Int(interval) / 60
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval) / 3600
            return "\(hours)h ago"
        } else {
            let days = Int(interval) / 86400
            return "\(days)d ago"
        }
    }
}
