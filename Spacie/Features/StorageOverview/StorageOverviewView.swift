import SwiftUI

// MARK: - StorageCategory

/// A single category in the storage breakdown (e.g., Applications, User Data, System).
struct StorageCategory: Identifiable, Sendable {
    let id: String
    let name: String
    let size: UInt64
    let color: Color
    let icon: String
    let percentage: Double
}

// MARK: - StorageRecommendation

/// An actionable recommendation to help the user free disk space.
struct StorageRecommendation: Identifiable, Sendable {
    let id: String
    let message: String
    let action: RecommendationAction
    let potentialSavings: UInt64

    enum RecommendationAction: Sendable {
        case openTrash
        case openStorage
        case none
    }
}

// MARK: - StorageOverviewViewModel

/// Analyzes a scanned file tree and breaks it down into system-level
/// storage categories with usage percentages and actionable recommendations.
///
/// Categories are determined by well-known path prefixes:
/// - **Applications**: `/Applications/`
/// - **User Data**: `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Movies`, `~/Music`, `~/Pictures`
/// - **System**: `/System/`, `/usr/`, `/bin/`, `/sbin/`, `/private/`
/// - **Library**: `~/Library/`
/// - **Other**: Everything that does not fall into the above categories
/// - **Purgeable**: Space macOS can reclaim automatically (from volume info)
/// - **Free**: Unallocated space on the volume
@MainActor
@Observable
final class StorageOverviewViewModel {

    // MARK: - State

    /// The volume this overview pertains to.
    var volume: VolumeInfo?

    /// Storage categories computed from the file tree and volume metadata.
    private(set) var categories: [StorageCategory] = []

    /// Actionable recommendations based on the analysis.
    private(set) var recommendations: [StorageRecommendation] = []

    /// Whether analysis is currently in progress.
    private(set) var isAnalyzing: Bool = false

    // MARK: - Private

    private let trashManager = TrashManager()

    // MARK: - Analysis

    /// Analyzes the given file tree against the volume to produce categories and recommendations.
    ///
    /// Iterates all top-level nodes in the tree, classifying each by its path prefix,
    /// then aggregates sizes per category. Purgeable and free space are derived from
    /// the volume metadata rather than the tree.
    ///
    /// - Parameters:
    ///   - tree: The scanned file tree.
    ///   - volume: The volume metadata including total/free/purgeable capacity.
    func analyze(tree: FileTree, volume: VolumeInfo) async {
        isAnalyzing = true
        self.volume = volume

        let home = NSHomeDirectory()
        let total = volume.totalCapacity

        // Accumulate sizes by category
        var applicationsSize: UInt64 = 0
        var userDataSize: UInt64 = 0
        var systemSize: UInt64 = 0
        var librarySize: UInt64 = 0
        var otherSize: UInt64 = 0

        let userDataPrefixes = [
            home + "/Documents",
            home + "/Desktop",
            home + "/Downloads",
            home + "/Movies",
            home + "/Music",
            home + "/Pictures",
        ]

        let systemPrefixes = [
            "/System",
            "/usr",
            "/bin",
            "/sbin",
            "/private",
        ]

        let nodeCount = tree.nodeCount
        guard nodeCount > 0 else { return }
        for index in 1...UInt32(nodeCount) {
            let info = tree.nodeInfo(at: index)

            // Only process files (not directories, to avoid double-counting).
            // Directories aggregate their children's sizes, so we count leaf files only.
            if info.isDirectory { continue }

            let path = info.fullPath
            let size = info.logicalSize

            if path.hasPrefix("/Applications") {
                applicationsSize += size
            } else if userDataPrefixes.contains(where: { path.hasPrefix($0) }) {
                userDataSize += size
            } else if systemPrefixes.contains(where: { path.hasPrefix($0) }) {
                systemSize += size
            } else if path.hasPrefix(home + "/Library") {
                librarySize += size
            } else {
                otherSize += size
            }
        }

        let purgeableSize = volume.purgeableSpace
        let freeSize = volume.freeSpace

        // Build categories
        let rawCategories: [(String, UInt64, Color, String)] = [
            ("Applications", applicationsSize, SpacieColors.applicationsColor, "app.badge"),
            ("User Data", userDataSize, SpacieColors.userData, "person.fill"),
            ("System", systemSize, SpacieColors.systemData, "gearshape.fill"),
            ("Library", librarySize, Color.purple, "books.vertical.fill"),
            ("Other", otherSize, Color(red: 0.74, green: 0.76, blue: 0.78), "folder.fill"),
            ("Purgeable", purgeableSize, SpacieColors.purgeableSpace, "arrow.3.trianglepath"),
            ("Free", freeSize, SpacieColors.freeSpace, "circle.dashed"),
        ]

        let computed = rawCategories.map { name, size, color, icon in
            let pct = total > 0 ? Double(size) / Double(total) : 0
            return StorageCategory(
                id: name.lowercased().replacingOccurrences(of: " ", with: "_"),
                name: name,
                size: size,
                color: color,
                icon: icon,
                percentage: pct
            )
        }

        // Build recommendations
        var recs: [StorageRecommendation] = []

        let currentTrashSize = await trashManager.trashSize()
        let oneGB: UInt64 = 1_073_741_824

        if currentTrashSize > oneGB {
            recs.append(StorageRecommendation(
                id: "empty-trash",
                message: "Empty Trash to free \(currentTrashSize.formattedSize)",
                action: .openTrash,
                potentialSavings: currentTrashSize
            ))
        }

        if purgeableSize > 0 {
            recs.append(StorageRecommendation(
                id: "purgeable",
                message: "\(purgeableSize.formattedSize) can be freed automatically by macOS",
                action: .openStorage,
                potentialSavings: purgeableSize
            ))
        }

        let tenPercentOfTotal = total / 10
        if freeSize < tenPercentOfTotal && total > 0 {
            recs.append(StorageRecommendation(
                id: "low-space",
                message: "Low disk space warning: only \(freeSize.formattedSize) free",
                action: .openStorage,
                potentialSavings: 0
            ))
        }

        self.categories = computed
        self.recommendations = recs
        self.isAnalyzing = false
    }
}

// MARK: - StorageOverviewView

/// Displays a horizontal stacked bar chart of storage categories
/// with a legend and actionable recommendations.
struct StorageOverviewView: View {

    @Bindable var viewModel: StorageOverviewViewModel
    private let permissionManager: PermissionManager?

    init(viewModel: StorageOverviewViewModel, permissionManager: PermissionManager? = nil) {
        self.viewModel = viewModel
        self.permissionManager = permissionManager
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.isAnalyzing {
                ProgressView("Analyzing storage...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let volume = viewModel.volume {
                headerSection(volume: volume)
                storageBar
                legendGrid
                recommendationsSection
                storageSettingsButton
            } else {
                ContentUnavailableView(
                    "No Volume Selected",
                    systemImage: "internaldrive",
                    description: Text("Select a volume and run a scan to see the storage overview.")
                )
            }
        }
        .padding()
    }

    // MARK: - Header

    private func headerSection(volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(volume.name)
                    .font(.title2.bold())
                Text("(\(volume.fileSystemType.displayName))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("\(volume.usedSpace.formattedSize) used of \(volume.totalCapacity.formattedSize)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Storage Bar

    private var storageBar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 1) {
                ForEach(viewModel.categories) { category in
                    let barWidth = max(category.percentage * width, category.size > 0 ? 2 : 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(category.color)
                        .frame(width: barWidth)
                        .help("\(category.name): \(category.size.formattedSize)")
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .background(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
    }

    // MARK: - Legend

    private var legendGrid: some View {
        LazyVGrid(columns: [
            GridItem(.adaptive(minimum: 180, maximum: 250), spacing: 12)
        ], alignment: .leading, spacing: 8) {
            ForEach(viewModel.categories.filter { $0.size > 0 }) { category in
                HStack(spacing: 8) {
                    Circle()
                        .fill(category.color)
                        .frame(width: 10, height: 10)
                    Image(systemName: category.icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(category.name)
                        .font(.callout)
                    Spacer()
                    Text(category.size.formattedSize)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Recommendations

    @ViewBuilder
    private var recommendationsSection: some View {
        if !viewModel.recommendations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recommendations")
                    .font(.headline)

                ForEach(viewModel.recommendations) { rec in
                    recommendationCard(rec)
                }
            }
        }
    }

    private func recommendationCard(_ recommendation: StorageRecommendation) -> some View {
        HStack {
            Image(systemName: recommendationIcon(for: recommendation))
                .foregroundStyle(recommendationColor(for: recommendation))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.message)
                    .font(.callout)
                if recommendation.potentialSavings > 0 {
                    Text("Potential savings: \(recommendation.potentialSavings.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if recommendation.action != .none {
                Button(actionLabel(for: recommendation.action)) {
                    performAction(recommendation.action)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    // MARK: - Storage Settings Button

    private var storageSettingsButton: some View {
        HStack {
            Spacer()
            Button {
                if let pm = permissionManager {
                    pm.openStorageSettings()
                } else {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
                }
            } label: {
                Label("Open Storage Settings", systemImage: "externaldrive")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func recommendationIcon(for recommendation: StorageRecommendation) -> String {
        switch recommendation.action {
        case .openTrash: "trash"
        case .openStorage: "externaldrive"
        case .none: "exclamationmark.triangle"
        }
    }

    private func recommendationColor(for recommendation: StorageRecommendation) -> Color {
        switch recommendation.id {
        case "low-space": .red
        case "empty-trash": .orange
        default: .blue
        }
    }

    private func actionLabel(for action: StorageRecommendation.RecommendationAction) -> String {
        switch action {
        case .openTrash: "Open Trash"
        case .openStorage: "Open Settings"
        case .none: ""
        }
    }

    private func performAction(_ action: StorageRecommendation.RecommendationAction) {
        switch action {
        case .openTrash:
            NSWorkspace.shared.open(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            )
        case .openStorage:
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!
            )
        case .none:
            break
        }
    }
}
