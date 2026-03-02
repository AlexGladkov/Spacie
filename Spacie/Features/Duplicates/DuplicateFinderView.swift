import SwiftUI

// MARK: - DuplicateFinderViewModel

@MainActor
@Observable
final class DuplicateFinderViewModel {

    // MARK: State

    var state: DuplicateScanState = .idle
    var groups: [DuplicateGroup] = []
    var expandedGroupId: String?
    var selectedStrategy: AutoSelectStrategy = .keepNewest

    // MARK: Engine

    private let engine = DuplicateEngine()
    private var scanTask: Task<Void, Never>?

    // MARK: Computed

    var totalWasted: UInt64 {
        groups.reduce(0) { $0 + $1.wastedSpace }
    }

    var totalGroupCount: Int {
        groups.count
    }

    var selectedForDeletion: [DuplicateFile] {
        groups.flatMap { group in
            group.files.filter(\.isSelected)
        }
    }

    var selectedForDeletionSize: UInt64 {
        selectedForDeletion.reduce(0) { $0 + $1.size }
    }

    var isScanning: Bool {
        switch state {
        case .idle, .completed, .error: return false
        default: return true
        }
    }

    var progressValue: Double {
        switch state {
        case .computingPartialHash(let progress): return progress
        case .computingFullHash(_, let progress): return progress
        case .completed: return 1.0
        default: return 0.0
        }
    }

    // MARK: Actions

    func startScan(tree: FileTree) async {
        cancelScan()

        scanTask = Task {
            let stream = await engine.findDuplicates(in: tree)

            for await event in stream {
                guard !Task.isCancelled else { break }
                self.handleEvent(event)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        Task { await engine.cancel() }
    }

    func computeFullHash(for groupId: String) async {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let group = groups[groupIndex]

        state = .computingFullHash(groupId: groupId, progress: 0)

        let urls = group.files.map(\.url)

        do {
            let hashGroups = try await engine.computeFullHash(for: urls)

            // Replace the old group with confirmed groups
            self.groups.removeAll { $0.id == groupId }

            for (hash, urls) in hashGroups where urls.count > 1 {
                let files = urls.compactMap { url -> DuplicateFile? in
                    guard let original = group.files.first(where: { $0.url == url }) else { return nil }
                    return original
                }
                let newGroup = DuplicateGroup(
                    id: "full-\(hash.prefix(16))",
                    fileSize: group.fileSize,
                    files: files,
                    hashLevel: .fullHash
                )
                self.groups.append(newGroup)
            }

            self.groups.sort { $0.wastedSpace > $1.wastedSpace }

            if case .computingFullHash = self.state {
                if let stats = self.buildStats() {
                    self.state = .completed(stats: stats)
                }
            }
        } catch {
            state = .error("Hash computation failed: \(error.localizedDescription)")
        }
    }

    func autoSelect(strategy: AutoSelectStrategy) {
        selectedStrategy = strategy

        for groupIndex in groups.indices {
            var files = groups[groupIndex].files

            // Determine which file to keep
            let keepIndex: Int
            switch strategy {
            case .keepNewest:
                keepIndex = files.indices.max(by: { files[$0].modificationDate < files[$1].modificationDate }) ?? 0
            case .keepOldest:
                keepIndex = files.indices.min(by: { files[$0].modificationDate < files[$1].modificationDate }) ?? 0
            case .keepShortestPath:
                keepIndex = files.indices.min(by: { files[$0].path.count < files[$1].path.count }) ?? 0
            }

            // Mark all except keeper for deletion
            for i in files.indices {
                files[i].isSelected = (i != keepIndex)
            }

            groups[groupIndex] = DuplicateGroup(
                id: groups[groupIndex].id,
                fileSize: groups[groupIndex].fileSize,
                files: files,
                hashLevel: groups[groupIndex].hashLevel
            )
        }
    }

    func toggleFileSelection(groupId: String, fileId: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var files = groups[groupIndex].files
        guard let fileIndex = files.firstIndex(where: { $0.id == fileId }) else { return }

        files[fileIndex].isSelected.toggle()

        // Ensure at least one file is NOT selected (prevent deleting all copies)
        let unselectedCount = files.filter { !$0.isSelected }.count
        if unselectedCount == 0 {
            // Revert the toggle
            files[fileIndex].isSelected = false
            return
        }

        groups[groupIndex] = DuplicateGroup(
            id: groups[groupIndex].id,
            fileSize: groups[groupIndex].fileSize,
            files: files,
            hashLevel: groups[groupIndex].hashLevel
        )
    }

    func sendToDropZone(dropZone: DropZoneViewModel) {
        for file in selectedForDeletion {
            let info = FileNodeInfo(
                id: 0,
                name: file.name,
                fullPath: file.path,
                logicalSize: file.size,
                physicalSize: file.size,
                isDirectory: false,
                fileType: FileType.from(extension: file.url.pathExtension),
                modificationDate: file.modificationDate,
                childCount: 0,
                depth: 0,
                flags: FileNodeFlags(rawValue: 0)
            )
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
        case .partialHashStarted:
            state = .computingPartialHash(progress: 0)
        case .partialHashProgress(let completed, let total):
            let progress = total > 0 ? Double(completed) / Double(total) : 0
            state = .computingPartialHash(progress: progress)
        case .partialHashCompleted(let newGroups):
            groups = newGroups
        case .fullHashStarted(let groupId, _):
            state = .computingFullHash(groupId: groupId, progress: 0)
        case .fullHashProgress(let groupId, let completed, let total):
            let progress = total > 0 ? Double(completed) / Double(total) : 0
            state = .computingFullHash(groupId: groupId, progress: progress)
        case .fullHashCompleted(let groupId, let newGroups):
            groups.removeAll { $0.id == groupId }
            groups.append(contentsOf: newGroups)
            groups.sort { $0.wastedSpace > $1.wastedSpace }
        case .error(let message):
            state = .error(message)
        case .completed(let stats):
            state = .completed(stats: stats)
        }
    }

    private func buildStats() -> DuplicateStats? {
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
            case .computingPartialHash(let progress):
                progressContentView(
                    title: "Computing partial hashes...",
                    detail: "\(Int(progress * 100))%",
                    progress: progress
                )
            case .computingFullHash(let groupId, let progress):
                progressContentView(
                    title: "Computing full hash...",
                    detail: "Group: \(groupId.prefix(8))... \(Int(progress * 100))%",
                    progress: progress
                )
            case .completed:
                if viewModel.groups.isEmpty {
                    emptyResultView
                } else {
                    groupListView
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
                            viewModel.sendToDropZone(dropZone: dropZone)
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
                        Task {
                            await viewModel.startScan(tree: tree)
                        }
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
            ForEach(viewModel.groups) { group in
                DuplicateGroupCard(
                    group: group,
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
                    Task {
                        await viewModel.startScan(tree: tree)
                    }
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
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { file.isSelected },
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
                    .foregroundStyle(file.isSelected ? .primary : .secondary)
                    .help(file.path)

                Text(file.modificationDate, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if file.isSelected {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 42)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(file.isSelected ? Color.red.opacity(0.05) : Color.clear)
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
