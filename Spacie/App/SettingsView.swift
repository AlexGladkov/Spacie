import SwiftUI

// MARK: - SettingsView

/// The macOS Settings window for Spacie, opened with Cmd+,.
///
/// Contains six tabs:
/// - **General**: Default visualization mode, size mode, and old file age threshold.
/// - **Smart Scan**: Scan profile, coverage threshold, and Smart Scan toggle.
/// - **Scan Exclusions**: Built-in and user-defined scan exclusion rules.
/// - **Protected Paths**: View and manage the user blocklist for deletion protection.
/// - **Cache**: View and manage cached scan data per volume.
/// - **About**: Application version, GitHub link, and license information.
///
/// All preferences are persisted with `@AppStorage` and take effect immediately.
struct SettingsView: View {

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            SmartScanSettingsTab()
                .tabItem {
                    Label("Smart Scan", systemImage: "bolt.circle")
                }

            ScanExclusionsSettingsTab()
                .tabItem {
                    Label("Scan Exclusions", systemImage: "eye.slash")
                }

            ProtectedPathsSettingsTab()
                .tabItem {
                    Label("Protected Paths", systemImage: "shield.lefthalf.filled")
                }

            CacheSettingsTab()
                .tabItem {
                    Label("Cache", systemImage: "archivebox")
                }

            #if DIRECT
            iOSTransferSettingsTab()
                .tabItem {
                    Label("iOS Transfer", systemImage: "iphone.and.arrow.right.and.arrow.left.inward")
                }
            #endif

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 500)
    }
}

// MARK: - General Tab

/// Settings for default behavior of the application.
private struct GeneralSettingsTab: View {

    @AppStorage("defaultVisualizationMode") private var defaultVisualizationMode: String = VisualizationMode.sunburst.rawValue
    @AppStorage("defaultSizeMode") private var defaultSizeMode: String = SizeMode.logical.rawValue
    @AppStorage("oldFileAgeMonths") private var oldFileAgeMonths: Int = 12

    private var vizBinding: Binding<VisualizationMode> {
        Binding(
            get: { VisualizationMode(rawValue: defaultVisualizationMode) ?? .sunburst },
            set: { defaultVisualizationMode = $0.rawValue }
        )
    }

    private var sizeBinding: Binding<SizeMode> {
        Binding(
            get: { SizeMode(rawValue: defaultSizeMode) ?? .logical },
            set: { defaultSizeMode = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Visualization") {
                Picker("Default view", selection: vizBinding) {
                    ForEach(VisualizationMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.systemImage).tag(mode)
                    }
                }

                Picker("Default size mode", selection: sizeBinding) {
                    ForEach(SizeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Old Files") {
                Picker("Consider files old after", selection: $oldFileAgeMonths) {
                    Text("6 months").tag(6)
                    Text("1 year").tag(12)
                    Text("2 years").tag(24)
                    Text("3 years").tag(36)
                }
                Text("Files not accessed within this period will appear in the Old Files panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Smart Scan Tab

/// Settings for the Smart Scan feature, which prioritizes important directories
/// and stops early once a coverage threshold is reached.
private struct SmartScanSettingsTab: View {

    @AppStorage("smartScanEnabled") private var smartScanEnabled: Bool = true
    @AppStorage("smartScanProfile") private var smartScanProfile: String = ScanProfileType.default.rawValue
    @AppStorage("smartScanCoverageThreshold") private var smartScanCoverageThreshold: Double = 0.95

    private var profileBinding: Binding<ScanProfileType> {
        Binding(
            get: { ScanProfileType(rawValue: smartScanProfile) ?? .default },
            set: { smartScanProfile = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Smart Scan") {
                Toggle("Enable Smart Scan", isOn: $smartScanEnabled)

                Picker("Scan Profile", selection: profileBinding) {
                    ForEach(ScanProfileType.allCases) { profile in
                        Text(profile.displayName).tag(profile)
                    }
                }
                .disabled(!smartScanEnabled)

                Picker("Coverage Threshold", selection: $smartScanCoverageThreshold) {
                    Text("90%").tag(0.90)
                    Text("95%").tag(0.95)
                    Text("99%").tag(0.99)
                    Text("100% (Full Scan)").tag(1.0)
                }
                .disabled(!smartScanEnabled)

                Text("Smart Scan prioritizes important directories and stops when the coverage threshold is reached. A lower threshold results in faster scans but less detail in the visualization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Protected Paths Tab

/// Displays and manages the user-defined blocklist of protected file paths.
///
/// Patterns are glob-style and are checked by ``BlocklistManager`` before
/// any file deletion. Adding a pattern here prevents Spacie from moving
/// matched files to Trash.
private struct ProtectedPathsSettingsTab: View {

    @State private var patterns: [String] = BlocklistManager.userPatterns
    @State private var newPattern: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protected paths cannot be deleted by Spacie.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Add new pattern
            HStack {
                TextField("Glob pattern (e.g., ~/Projects/**)", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addPattern() }

                Button("Add") {
                    addPattern()
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Hardcoded paths (read-only)
            GroupBox("System-Protected (cannot be changed)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(BlocklistManager.sipProtectedPaths).sorted(), id: \.self) { path in
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(height: 80)
            }

            // User patterns
            GroupBox("User Blocklist") {
                if patterns.isEmpty {
                    Text("No custom patterns defined.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    List {
                        ForEach(patterns, id: \.self) { pattern in
                            HStack {
                                Image(systemName: "shield.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.blue)
                                Text(pattern)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button {
                                    removePattern(pattern)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(minHeight: 80)
                }
            }
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    private func addPattern() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try BlocklistManager.addPattern(trimmed)
            patterns = BlocklistManager.userPatterns
            newPattern = ""
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removePattern(_ pattern: String) {
        do {
            try BlocklistManager.removePattern(pattern)
            patterns = BlocklistManager.userPatterns
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Scan Exclusions Tab

/// Displays built-in and user-defined scan exclusion rules.
///
/// Built-in exclusions (basenames and path prefixes) are shown read-only
/// in a disclosure group. User exclusions support CRUD via
/// ``ScanExclusionManager``.
private struct ScanExclusionsSettingsTab: View {

    @State private var userExclusions: [String] = ScanExclusionManager.userExclusions
    @State private var newPattern: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Excluded directories are skipped during scanning, dramatically reducing scan time.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Add new exclusion
            HStack {
                TextField("Directory name or path prefix (e.g., .venv or ~/Backups)", text: $newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addExclusion() }

                Button("Add") {
                    addExclusion()
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Built-in exclusions (read-only)
            DisclosureGroup("Built-in Exclusions") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Directory names")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(ScanExclusionManager.defaultBasenames.sorted().joined(separator: ", "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Divider()

                        Text("Path prefixes")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ForEach(ScanExclusionManager.defaultPathPrefixes, id: \.self) { prefix in
                            Text(prefix)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(height: 100)
            }

            // User exclusions
            GroupBox("Custom Exclusions") {
                if userExclusions.isEmpty {
                    Text("No custom exclusions defined.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                } else {
                    List {
                        ForEach(userExclusions, id: \.self) { pattern in
                            HStack {
                                Image(systemName: "eye.slash")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(pattern)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button {
                                    removeExclusion(pattern)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    .frame(minHeight: 60)
                }
            }
        }
        .padding()
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    private func addExclusion() {
        let trimmed = newPattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try ScanExclusionManager.addExclusion(trimmed)
            userExclusions = ScanExclusionManager.userExclusions
            newPattern = ""
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func removeExclusion(_ pattern: String) {
        do {
            try ScanExclusionManager.removeExclusion(pattern)
            userExclusions = ScanExclusionManager.userExclusions
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Cache Tab

/// Displays cached scan data per volume and allows clearing individual caches.
///
/// Each row shows the volume name, total cache size (blob + WAL), last scan date,
/// node count, and completion status. The "Clear" button deletes the cache file,
/// WAL companion, and directory size companion for the selected volume.
private struct CacheSettingsTab: View {

    @State private var cacheEntries: [ScanCache.CacheInfo] = []
    @State private var showClearConfirmation: Bool = false
    @State private var volumeToClear: ScanCache.CacheInfo?

    /// Byte count formatter configured for file-size display.
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Number formatter with grouping separators for node counts.
    private static let nodeCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cached scan data allows instant display of previous results on launch.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if cacheEntries.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "archivebox")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No cached scan data")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(cacheEntries, id: \.volumeId) { entry in
                        cacheRow(for: entry)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding()
        .onAppear {
            loadCacheEntries()
        }
        .alert(
            "Clear Cache",
            isPresented: $showClearConfirmation,
            presenting: volumeToClear
        ) { entry in
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                clearCache(for: entry)
            }
        } message: { entry in
            Text("This will delete cached scan data for \(entry.volumeName). The next scan will start from scratch.")
        }
    }

    /// Builds a single row displaying cache metadata for a volume.
    @ViewBuilder
    private func cacheRow(for entry: ScanCache.CacheInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.volumeName)
                    .font(.callout.bold())

                HStack(spacing: 16) {
                    Label(
                        Self.byteFormatter.string(fromByteCount: Int64(entry.cacheSize + entry.walSize)),
                        systemImage: "doc.zipper"
                    )

                    Label(
                        formattedNodeCount(entry.nodeCount),
                        systemImage: "list.number"
                    )

                    Label(
                        entry.isComplete ? "Complete" : "Partial",
                        systemImage: entry.isComplete ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(entry.isComplete ? .green : .orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let date = entry.lastScanDate {
                    Text(formattedDate(date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                volumeToClear = entry
                showClearConfirmation = true
            } label: {
                Text("Clear")
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    /// Loads cache metadata for all known cached volumes.
    private func loadCacheEntries() {
        let volumeIds = ScanCache.allCachedVolumeIds()
        cacheEntries = volumeIds.compactMap { ScanCache.cacheInfo(for: $0) }
            .sorted { ($0.cacheSize + $0.walSize) > ($1.cacheSize + $1.walSize) }
    }

    /// Deletes cache files for a volume and refreshes the list.
    private func clearCache(for entry: ScanCache.CacheInfo) {
        let cache = ScanCache(volumeId: entry.volumeId)
        cache.invalidate()
        loadCacheEntries()
    }

    /// Formats a date using relative conventions for today/yesterday and
    /// abbreviated date + time for older entries.
    private func formattedDate(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            return "Today, \(timeFormatter.string(from: date))"
        }

        if calendar.isDateInYesterday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm"
            return "Yesterday, \(timeFormatter.string(from: date))"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Formats a node count with grouping separators (e.g., "1,234,567 items").
    private func formattedNodeCount(_ count: Int) -> String {
        let formatted = Self.nodeCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(formatted) items"
    }
}

// MARK: - iOS Transfer Tab (Direct only)

#if DIRECT
/// Settings for the iOS App Transfer feature.
///
/// Lets the user choose a custom folder for extracted IPA archives and
/// shows the total space currently occupied by archived apps.
/// This tab is only present in Direct (non-App Store) builds.
private struct iOSTransferSettingsTab: View {

    /// User-configured archive folder path. Empty string means "use default".
    @AppStorage("iOSArchiveDirectory") private var customPath: String = ""

    @State private var totalSize: UInt64?
    @State private var isLoadingSize = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// The path actually in use (custom if valid, otherwise default).
    private var effectivePath: String {
        customPath.isEmpty ? AppArchiveService.defaultArchiveDirectory.path : customPath
    }

    var body: some View {
        Form {
            Section("Archive Folder") {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    Text(effectivePath)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button("Change…") { changeArchiveDirectory() }

                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: effectivePath)]
                        )
                    }

                    if !customPath.isEmpty {
                        Button("Reset to Default", role: .destructive) {
                            customPath = ""
                            refreshSize()
                        }
                    }
                }
                .controlSize(.small)
            }

            Section("Storage") {
                HStack {
                    Text("Total archive size")
                    Spacer()
                    if isLoadingSize {
                        ProgressView()
                            .controlSize(.mini)
                    } else if let size = totalSize {
                        Text(Self.byteFormatter.string(fromByteCount: Int64(size)))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { refreshSize() }
    }

    private func changeArchiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose Archive Folder"
        panel.message = "Select where to save extracted IPA files."
        if panel.runModal() == .OK, let url = panel.url {
            customPath = url.path
            refreshSize()
        }
    }

    private func refreshSize() {
        isLoadingSize = true
        totalSize = nil
        Task {
            let service = AppArchiveService()
            let size = try? await service.totalArchiveSize()
            await MainActor.run {
                totalSize = size
                isLoadingSize = false
            }
        }
    }
}
#endif

// MARK: - About Tab

/// Displays application information, links, and license.
private struct AboutSettingsTab: View {

    private let appVersion: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "internaldrive")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Spacie")
                .font(.title.bold())

            Text("Disk Space Analyzer for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/spacie-app/spacie")!) {
                    Label("GitHub", systemImage: "link")
                }

                Text("|")
                    .foregroundStyle(.quaternary)

                Link(destination: URL(string: "https://github.com/spacie-app/spacie/blob/main/LICENSE")!) {
                    Label("License", systemImage: "doc.text")
                }
            }
            .font(.callout)

            Text("Free for personal use. Commercial use prohibited.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
