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

    private static let buildVersion: String = {
        let date = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd.HHmm"
        return "b" + fmt.string(from: date)
    }()

    var body: some View {
        HStack(spacing: 0) {
            content
            cacheStatusBanner
            Text(Self.buildVersion)
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.leading, 8)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - Cache Status Banner

    /// Displays a subtle text indicator for incremental cache status.
    ///
    /// Shown between the main info bar content and the build version label.
    /// Uses secondary/tertiary foreground styling to remain unobtrusive.
    @ViewBuilder
    private var cacheStatusBanner: some View {
        switch viewModel.cacheStatus {
        case .none:
            EmptyView()

        case .loadedChecking(let lastScanDate):
            HStack(spacing: 4) {
                separator
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Cached data from \(formattedCacheDate(lastScanDate)), checking for changes...")
                    .foregroundStyle(.tertiary)
            }

        case .changesFound(let addedBytes, let dirCount):
            HStack(spacing: 4) {
                separator
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text("Found changes: \(formattedBytesDelta(addedBytes)) in \(dirCount) \(dirCount == 1 ? "directory" : "directories")")
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            HStack(spacing: 4) {
                separator
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                Text("Data is up to date")
                    .foregroundStyle(.tertiary)
            }

        case .corrupted:
            HStack(spacing: 4) {
                separator
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Cache corrupted, starting full scan")
                    .foregroundStyle(.orange)
            }

        case .volumeNotMounted:
            HStack(spacing: 4) {
                separator
                Image(systemName: "externaldrive.badge.xmark")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Text("Volume not mounted")
                    .foregroundStyle(.orange)
            }

        case .resumingScan:
            // No banner -- standard scan progress is shown in the main content area
            EmptyView()
        }
    }

    /// Formats a date for cache status display (e.g., "today, 14:30" or "Feb 23, 09:15").
    private func formattedCacheDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'today,' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'yesterday,' HH:mm"
        } else {
            formatter.dateFormat = "MMM d, HH:mm"
        }

        return formatter.string(from: date)
    }

    /// Formats a byte delta for display (e.g., "+1.2 GB" or "-340 MB").
    private func formattedBytesDelta(_ bytes: Int64) -> String {
        let prefix = bytes >= 0 ? "+" : ""
        let absBytes = UInt64(abs(bytes))
        return "\(prefix)\(absBytes.formattedSize)"
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                scanPhaseIndicator

                separator

                if progress.phase == .red {
                    statLabel(icon: "folder", text: progress.directoriesScanned.formattedCount + " dirs")
                } else {
                    statLabel(icon: "doc", text: progress.filesScanned.formattedCount + " files")
                    separator
                    statLabel(icon: "internaldrive", text: progress.totalPhysicalSizeScanned.formattedSize)
                }
                separator
                statLabel(icon: "clock", text: liveElapsed(at: context.date).formattedDuration)

                if progress.skippedDirectories > 0 {
                    separator
                    statLabel(icon: "eye.slash", text: progress.skippedDirectories.formattedCount + " skipped")
                        .foregroundStyle(.orange)
                }

                Spacer()
            }
        }
    }

    /// Computes wall-clock elapsed time from the scan start date.
    /// Falls back to 0 if no scan is in progress.
    private func liveElapsed(at now: Date) -> TimeInterval {
        guard let start = viewModel.scanStartDate else { return 0 }
        return now.timeIntervalSince(start)
    }

    // MARK: - Completed State

    private func completedContent(stats: ScanStats) -> some View {
        HStack(spacing: 12) {
            scanPhaseIndicator
            separator

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

    // MARK: - Scan Phase Indicator

    /// Traffic light indicator showing the current scan phase (Red / Yellow / Green).
    @ViewBuilder
    private var scanPhaseIndicator: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            Text(phaseText)
        }
    }

    private var phaseColor: Color {
        switch viewModel.scanPhase {
        case .red: return .red
        case .yellow: return .yellow
        case .smartGreen: return SpacieColors.smartGreenIndicator
        case .green: return .green
        }
    }

    private var phaseText: String {
        switch viewModel.scanPhase {
        case .red:
            if case .scanning(let progress) = viewModel.scanState {
                return "Scanning structure... \(progress.directoriesScanned.formattedCount) directories"
            }
            return "Scanning structure..."
        case .yellow:
            if case .scanning(let progress) = viewModel.scanState {
                let completed = progress.deepScanDirsCompleted
                let total = progress.deepScanDirsTotal
                if total > 0 {
                    let pct = Int(Double(completed) / Double(total) * 100)
                    return "Approximate data -- deep scan: \(pct)% (\(completed) / \(total) directories)"
                }
            }
            return "Approximate data -- deep scan in progress"
        case .smartGreen:
            if case .scanning(let progress) = viewModel.scanState,
               let coverage = progress.coveragePercent {
                let pct = Int(coverage * 100)
                return "Smart Scan: \(pct)% covered (\(progress.scannedBytes.formattedSize) / \(progress.estimatedUsedSpace.formattedSize) used)"
            }
            if case .completed = viewModel.scanState {
                return "Smart Scan complete"
            }
            return "Smart Scan complete"
        case .green:
            if case .completed(let stats) = viewModel.scanState {
                return "Scan complete -- \(stats.totalFiles.formattedCount) files, \(stats.totalLogicalSize.formattedSize)"
            }
            return "Scan complete"
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
