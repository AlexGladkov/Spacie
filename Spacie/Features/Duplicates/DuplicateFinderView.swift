import SwiftUI

// MARK: - DuplicateFinderViewModel

@MainActor
@Observable
final class DuplicateFinderViewModel {

    // MARK: State

    var state: DuplicateScanState = .idle

    var groups: [DuplicateGroup] = [] {
        didSet {
            _totalWasted = groups.reduce(0) { $0 + $1.wastedSpace }
            _totalDuplicateFiles = groups.reduce(0) { $0 + $1.fileCount }
            recomputeFilteredGroups()
            recomputeSelectedForDeletion()
        }
    }

    var expandedGroupId: String?
    var selectedStrategy: AutoSelectStrategy = .keepNewest

    var selectedFileIds: Set<String> = [] {
        didSet { recomputeSelectedForDeletion() }
    }

    var sortMode: DuplicateSortMode = .wastedSpace {
        didSet { recomputeFilteredGroups() }
    }

    var searchText: String = "" {
        didSet { recomputeFilteredGroups() }
    }

    var filterOptions: DuplicateFilterOptions = DuplicateFilterOptions()

    // MARK: Engine

    private let engine = DuplicateEngine()
    private var scanTask: Task<Void, Never>?

    // MARK: Cached Computed (updated only when source data changes)

    /// Filtered and sorted groups. Recomputed only when groups/searchText/sortMode change.
    private(set) var filteredGroups: [DuplicateGroup] = []

    private var _totalWasted: UInt64 = 0
    private var _totalDuplicateFiles: Int = 0

    var totalWasted: UInt64 { _totalWasted }

    var totalGroupCount: Int { groups.count }

    var totalDuplicateFiles: Int { _totalDuplicateFiles }

    /// Files selected for deletion. Recomputed only when selectedFileIds or groups change.
    private(set) var selectedForDeletion: [DuplicateFile] = []
    private(set) var selectedForDeletionSize: UInt64 = 0

    // MARK: Private Recompute

    private func recomputeFilteredGroups() {
        var result = groups
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { group in
                group.files.contains { $0.name.lowercased().contains(q) }
            }
        }
        switch sortMode {
        case .wastedSpace: result.sort { $0.wastedSpace > $1.wastedSpace }
        case .count:       result.sort { $0.fileCount > $1.fileCount }
        case .fileSize:    result.sort { $0.fileSize > $1.fileSize }
        }
        filteredGroups = result
    }

    private func recomputeSelectedForDeletion() {
        let selected = groups.flatMap { $0.files.filter { selectedFileIds.contains($0.id) } }
        selectedForDeletion = selected
        selectedForDeletionSize = selected.reduce(0) { $0 + $1.size }
    }

    var currentStats: DuplicateStats? {
        if case .completed(let stats) = state { return stats }
        return nil
    }

    var isScanning: Bool {
        switch state {
        case .idle, .completed, .error: return false
        default: return true
        }
    }

    var progressValue: Double {
        switch state {
        case .hashing(let progress): return progress.fraction
        case .completed: return 1.0
        default: return 0.0
        }
    }

    // MARK: Actions

    func startScan(tree: FileTree) {
        cancelScan()
        groups = []
        selectedFileIds.removeAll()
        state = .groupingBySize

        scanTask = Task {
            let stream = await engine.findDuplicates(in: tree, filterOptions: filterOptions)

            for await event in stream {
                guard !Task.isCancelled else { break }
                self.handleEvent(event)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if case .completed = state { } else { state = .idle }
    }

    func onTreeChanged(tree: FileTree) {
        cancelScan()
        groups = []
        selectedFileIds.removeAll()
        state = .idle
    }

    func computeFullHash(for groupId: String) async {
        guard let group = groups.first(where: { $0.id == groupId }) else { return }

        do {
            let confirmedGroups = try await engine.computeFullHash(for: group)

            // Replace the old group with confirmed groups
            self.groups.removeAll { $0.id == groupId }
            self.groups.append(contentsOf: confirmedGroups)
            self.groups.sort { $0.wastedSpace > $1.wastedSpace }

            // Update stats if we were in completed state
            if case .completed = self.state {
                self.state = .completed(buildStats())
            }
        } catch {
            // Silently handle -- the group remains at partial hash level
        }
    }

    func autoSelect(strategy: AutoSelectStrategy) {
        selectedFileIds.removeAll()
        selectedStrategy = strategy
        for group in groups {
            let keepIdx: Int
            switch strategy {
            case .keepNewest:
                keepIdx = group.files.indices.max(by: {
                    group.files[$0].modificationDate < group.files[$1].modificationDate
                }) ?? 0
            case .keepOldest:
                keepIdx = group.files.indices.min(by: {
                    group.files[$0].modificationDate < group.files[$1].modificationDate
                }) ?? 0
            case .keepShortestPath:
                keepIdx = group.files.indices.min(by: {
                    group.files[$0].path.count < group.files[$1].path.count
                }) ?? 0
            }
            for (i, file) in group.files.enumerated() where i != keepIdx {
                selectedFileIds.insert(file.id)
            }
        }
    }

    func toggleFileSelection(groupId: String, fileId: String) {
        guard let group = groups.first(where: { $0.id == groupId }) else { return }
        if selectedFileIds.contains(fileId) {
            selectedFileIds.remove(fileId)
        } else {
            // Ensure at least one file remains unselected
            let selectedInGroup = group.files.filter { selectedFileIds.contains($0.id) }.count
            if selectedInGroup < group.files.count - 1 {
                selectedFileIds.insert(fileId)
            }
        }
    }

    func sendToDropZone(dropZone: DropZoneViewModel, tree: FileTree) {
        for file in selectedForDeletion {
            let info = tree.nodeInfo(at: file.treeIndex)
            dropZone.addItem(info)
        }
    }

    // MARK: Private

    private func handleEvent(_ event: DuplicateEngineEvent) {
        switch event {
        case .sizeGroupingStarted:
            state = .groupingBySize
        case .sizeGroupingCompleted:
            break
        case .hashingProgress(let progress):
            state = .hashing(progress)
        case .hashingCompleted(let newGroups):
            groups = newGroups
        case .error(let message):
            state = .error(message)
        case .completed(let stats):
            state = .completed(stats)
        }
    }

    private func buildStats() -> DuplicateStats {
        DuplicateStats(
            groupCount: groups.count,
            totalDuplicateFiles: groups.reduce(0) { $0 + $1.fileCount },
            totalWastedSpace: totalWasted,
            scanDuration: 0
        )
    }
}

// MARK: - DuplicateFinderView

struct DuplicateFinderView: View {
    @Bindable var viewModel: DuplicateFinderViewModel
    var dropZoneViewModel: DropZoneViewModel?
    var tree: FileTree?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            switch viewModel.state {
            case .idle:
                idleView
            case .groupingBySize:
                progressContentView(
                    title: "Grouping files by size...",
                    detail: nil,
                    progress: nil
                )
            case .hashing(let scanProgress):
                progressContentView(
                    title: "Computing partial hashes...",
                    detail: "\(scanProgress.filesHashed)/\(scanProgress.totalFiles) files (\(Int(scanProgress.fraction * 100))%)",
                    progress: scanProgress.fraction
                )
            case .completed:
                if viewModel.groups.isEmpty {
                    emptyResultView
                } else {
                    VStack(spacing: 0) {
                        filterBar
                        Divider()
                        groupListView
                        statusBar
                    }
                }
            case .error(let message):
                errorView(message)
            }
        }
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Finder")
                    .font(.headline)
                if !viewModel.groups.isEmpty {
                    Text("\(viewModel.totalGroupCount) groups, \(viewModel.totalWasted.formattedSize) wasted")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if viewModel.isScanning {
                Button("Cancel") {
                    viewModel.cancelScan()
                }
            } else {
                if !viewModel.groups.isEmpty {
                    // Auto-select strategy
                    Menu {
                        ForEach(AutoSelectStrategy.allCases) { strategy in
                            Button(strategy.displayName) {
                                viewModel.autoSelect(strategy: strategy)
                            }
                        }
                    } label: {
                        Label("Auto-Select", systemImage: "wand.and.stars")
                    }

                    // Clean button
                    if let dropZone = dropZoneViewModel, !viewModel.selectedForDeletion.isEmpty {
                        Button {
                            if let tree {
                                viewModel.sendToDropZone(dropZone: dropZone, tree: tree)
                            }
                        } label: {
                            Label(
                                "Clean Selected (\(viewModel.selectedForDeletionSize.formattedSize))",
                                systemImage: "trash"
                            )
                        }
                        .tint(.red)
                    }
                }

                Button {
                    if let tree {
                        viewModel.startScan(tree: tree)
                    }
                } label: {
                    Label("Scan", systemImage: "magnifyingglass")
                }
                .disabled(tree == nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Filter Bar

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search duplicates...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 220)

            // Min size menu
            Menu {
                Button("4 KB") { viewModel.filterOptions.minFileSize = 4096 }
                Button("64 KB") { viewModel.filterOptions.minFileSize = 65_536 }
                Button("1 MB") { viewModel.filterOptions.minFileSize = 1_048_576 }
                Button("10 MB") { viewModel.filterOptions.minFileSize = 10_485_760 }
                Button("100 MB") { viewModel.filterOptions.minFileSize = 104_857_600 }
            } label: {
                Label("Min: \(viewModel.filterOptions.minFileSize.formattedSize)", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
            }

            Spacer()

            // Sort mode
            Picker("Sort", selection: $viewModel.sortMode) {
                ForEach(DuplicateSortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Status Bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            if let stats = viewModel.currentStats {
                Text("\(stats.groupCount) groups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(stats.totalDuplicateFiles) duplicates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(stats.totalWastedSpace.formattedSize) wasted")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            if !viewModel.selectedForDeletion.isEmpty {
                Text("\(viewModel.selectedForDeletion.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.selectedForDeletionSize.formattedSize)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Idle

    private var idleView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Find Duplicate Files")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Click Scan to search for duplicate files using progressive hashing.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Progress

    private func progressContentView(title: String, detail: String?, progress: Double?) -> some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 200)
            }
            Button("Cancel") {
                viewModel.cancelScan()
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty Result

    private var emptyResultView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("No Duplicates Found")
                .font(.title3)
            Text("Your files are all unique.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Group List

    private var groupListView: some View {
        List {
            ForEach(viewModel.filteredGroups) { group in
                DuplicateGroupCard(
                    group: group,
                    selectedFileIds: viewModel.selectedFileIds,
                    isExpanded: viewModel.expandedGroupId == group.id,
                    onToggleExpand: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if viewModel.expandedGroupId == group.id {
                                viewModel.expandedGroupId = nil
                            } else {
                                viewModel.expandedGroupId = group.id
                                // Trigger full hash if needed
                                if group.hashLevel == .partialHash {
                                    Task {
                                        await viewModel.computeFullHash(for: group.id)
                                    }
                                }
                            }
                        }
                    },
                    onToggleFileSelection: { fileId in
                        viewModel.toggleFileSelection(groupId: group.id, fileId: fileId)
                    }
                )
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    // MARK: Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Scan Error")
                .font(.title3)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Button("Try Again") {
                if let tree {
                    viewModel.startScan(tree: tree)
                }
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DuplicateGroupCard

struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let selectedFileIds: Set<String>
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleFileSelection: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            Button(action: onToggleExpand) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    fileIcon
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.files.first?.name ?? "Unknown")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text("\(group.fileCount) copies")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(group.fileSize.formattedSize + " each")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            hashLevelBadge
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(group.wastedSpace.formattedSize)
                            .font(.callout.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.red)
                        Text("wasted")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded file list
            if isExpanded {
                Divider()
                    .padding(.leading, 42)

                ForEach(group.files) { file in
                    DuplicateFileRow(
                        file: file,
                        isSelected: selectedFileIds.contains(file.id),
                        onToggleSelection: { onToggleFileSelection(file.id) }
                    )
                }
            }
        }
    }

    private var fileIcon: some View {
        let ext = group.files.first.map { URL(fileURLWithPath: $0.path).pathExtension } ?? ""
        let fileType = FileType.from(extension: ext)
        return Image(systemName: iconName(for: fileType))
            .foregroundStyle(SpacieColors.color(for: fileType))
    }

    @ViewBuilder
    private var hashLevelBadge: some View {
        let (text, color): (String, Color) = switch group.hashLevel {
        case .sizeOnly:     ("Size", .gray)
        case .partialHash:  ("Partial", .orange)
        case .fullHash:     ("Confirmed", .green)
        }
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }

    private func iconName(for fileType: FileType) -> String {
        switch fileType {
        case .video:       return "film"
        case .audio:       return "music.note"
        case .image:       return "photo"
        case .document:    return "doc.fill"
        case .archive:     return "archivebox.fill"
        case .code:        return "chevron.left.forwardslash.chevron.right"
        case .application: return "app.fill"
        case .system:      return "gearshape.fill"
        case .other:       return "doc"
        }
    }
}

// MARK: - DuplicateFileRow

struct DuplicateFileRow: View {
    let file: DuplicateFile
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelection() }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(abbreviatedPath(file.path))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .help(file.path)

                Text(file.modificationDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(isSelected ? Color.red.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Preview

#Preview("Duplicate Finder - Idle") {
    DuplicateFinderView(viewModel: DuplicateFinderViewModel())
        .frame(width: 700, height: 500)
}
