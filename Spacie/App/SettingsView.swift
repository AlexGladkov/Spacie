import SwiftUI

// MARK: - SettingsView

/// The macOS Settings window for Spacie, opened with Cmd+,.
///
/// Contains three tabs:
/// - **General**: Default visualization mode, size mode, and old file age threshold.
/// - **Protected Paths**: View and manage the user blocklist for deletion protection.
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

            ProtectedPathsSettingsTab()
                .tabItem {
                    Label("Protected Paths", systemImage: "shield.lefthalf.filled")
                }

            AboutSettingsTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 360)
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
