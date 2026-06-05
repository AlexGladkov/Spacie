import SwiftUI
import QuickLook

// MARK: - LargeFilesMode

enum LargeFilesMode: Hashable, Sendable {
    case topN(Int)
    case threshold(UInt64)

    var displayName: String {
        switch self {
        case .topN(let count):  "Top \(count)"
        case .threshold(let s): ">\u{00A0}\(s.formattedSizeShort)"
        }
    }

    static let topNPresets: [LargeFilesMode] = [
        .topN(50), .topN(100), .topN(500)
    ]

    static let thresholdPresets: [LargeFilesMode] = [
        .threshold(10_000_000),        // 10 MB
        .threshold(50_000_000),        // 50 MB
        .threshold(100_000_000),       // 100 MB
        .threshold(500_000_000),       // 500 MB
        .threshold(1_000_000_000),     // 1 GB
    ]
}

// MARK: - SortOrder

struct SortOrder: Equatable, Sendable {
    enum Field: String, CaseIterable, Sendable {
        case size, name, date, type
    }

    var field: Field
    var ascending: Bool

    mutating func toggle(field newField: Field) {
        if self.field == newField {
            ascending.toggle()
        } else {
            self.field = newField
            ascending = newField == .name
        }
    }

    static let defaultLargeFiles = SortOrder(field: .size, ascending: false)
}

// MARK: - LargeFilesViewModel

@MainActor
@Observable
final class LargeFilesViewModel {

    // MARK: State

    var mode: LargeFilesMode = .topN(100)
    var files: [FileNodeInfo] = []
    var sortOrder: SortOrder = .defaultLargeFiles
    var selectedFiles: Set<UInt32> = []
    var searchText: String = ""
    var isRefreshing: Bool = false

    // MARK: Computed

    var filteredFiles: [FileNodeInfo] {
        let base: [FileNodeInfo]
        if searchText.isEmpty {
            base = files
        } else {
            let query = searchText.lowercased()
            base = files.filter { $0.name.lowercased().contains(query) }
        }
        return sorted(base)
    }

    var selectionSummary: String {
        guard !selectedFiles.isEmpty else { return "" }
        let totalSize = files.filter { selectedFiles.contains($0.id) }.reduce(UInt64(0)) { $0 + $1.logicalSize }
        return "\(selectedFiles.count) selected (\(totalSize.formattedSize))"
    }

    // MARK: Refresh

    // Regular MainActor-isolated; cancelled from `isolated deinit` (Swift 6.1+).
    private var refreshTask: Task<Void, Never>?

    isolated deinit {
        // Cancel the detached scan so a dismissed view-model doesn't keep
        // walking the FileTree (5M+ nodes) and mutating orphaned MainActor state.
        refreshTask?.cancel()
    }

    func refresh(tree: FileTree, sizeMode: SizeMode) {
        refreshTask?.cancel()
        isRefreshing = true

        let currentMode = mode
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                switch currentMode {
                case .topN(let count):
                    return tree.topFiles(count: count, minSize: nil)
                        .map { tree.nodeInfo(at: $0) }
                case .threshold(let minSize):
                    return tree.topFiles(count: Int.max, minSize: minSize)
                        .map { tree.nodeInfo(at: $0) }
                }
            }.value

            guard let self else { return }
            guard !Task.isCancelled else { return }

            self.files = result
            let validIds = Set(result.map(\.id))
            self.selectedFiles = self.selectedFiles.intersection(validIds)
            self.isRefreshing = false
        }
    }

    // MARK: Selection

    func toggleSelection(_ id: UInt32, extendSelection: Bool) {
        if extendSelection {
            if selectedFiles.contains(id) {
                selectedFiles.remove(id)
            } else {
                selectedFiles.insert(id)
            }
        } else {
            selectedFiles = [id]
        }
    }

    func selectRange(to id: UInt32) {
        guard let lastSelected = selectedFiles.first,
              let startIndex = filteredFiles.firstIndex(where: { $0.id == lastSelected }),
              let endIndex = filteredFiles.firstIndex(where: { $0.id == id }) else {
            selectedFiles = [id]
            return
        }
        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        let rangeIds = Set(filteredFiles[range].map(\.id))
        selectedFiles.formUnion(rangeIds)
    }

    func selectAll() {
        selectedFiles = Set(filteredFiles.map(\.id))
    }

    // MARK: Sort

    func toggleSort(_ field: SortOrder.Field) {
        sortOrder.toggle(field: field)
    }

    private func sorted(_ items: [FileNodeInfo]) -> [FileNodeInfo] {
        items.sorted { a, b in
            let result: Bool
            switch sortOrder.field {
            case .size:
                result = a.logicalSize < b.logicalSize
            case .name:
                result = a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .date:
                result = a.modificationDate < b.modificationDate
            case .type:
                result = a.fileType.displayName < b.fileType.displayName
            }
            return sortOrder.ascending ? result : !result
        }
    }

    // MARK: Selected FileNodeInfos

    var selectedFileInfos: [FileNodeInfo] {
        files.filter { selectedFiles.contains($0.id) }
    }
}

// MARK: - LargeFilesView

struct LargeFilesView: View {
    @Bindable var viewModel: LargeFilesViewModel
    var dropZoneViewModel: DropZoneViewModel?
    var tree: FileTree?
    var sizeMode: SizeMode = .logical

    @State private var quickLookURL: URL?
    @State private var showQuickLook = false
    @State private var trashTargetInfos: [FileNodeInfo] = []
    @State private var showTrashConfirm: Bool = false
    @State private var trashError: String?
    @State private var showTrashError: Bool = false
    @Environment(\.openURL) private var openURL

    /// Callback invoked when files are trashed — host (AppViewModel) uses
    /// it to bump treeVersion and re-aggregate sizes.
    var onFilesTrashed: (([UInt32]) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ContentStateView(
                isLoading: viewModel.isRefreshing,
                isEmpty: viewModel.filteredFiles.isEmpty,
                loadingTitle: "Finding large files…",
                loadingSubtitle: "Walking the tree to collect files above the threshold.",
                emptyIcon: "tray",
                emptyTitle: "No large files found",
                emptyMessage: "Try adjusting the threshold or scanning a different volume."
            ) {
                fileTable
            }
            if !viewModel.selectionSummary.isEmpty {
                statusBar
            }
        }
        .quickLookPreview($quickLookURL)
        .onAppear {
            if let tree {
                viewModel.refresh(tree: tree, sizeMode: sizeMode)
            }
        }
        .alert(
            trashConfirmTitle,
            isPresented: $showTrashConfirm
        ) {
            Button("Cancel", role: .cancel) { trashTargetInfos = [] }
            Button("Move to Trash", role: .destructive) {
                performTrash(infos: trashTargetInfos)
            }
        } message: {
            Text(trashConfirmMessage)
        }
        .alert("Error", isPresented: $showTrashError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let trashError {
                Text(trashError)
            }
        }
    }

    private var trashConfirmTitle: String {
        trashTargetInfos.count == 1
            ? "Move \u{201C}\(trashTargetInfos.first?.name ?? "")\u{201D} to Trash?"
            : "Move \(trashTargetInfos.count) files to Trash?"
    }

    private var trashConfirmMessage: String {
        let total = trashTargetInfos.reduce(UInt64(0)) { $0 + $1.logicalSize }
        return "Frees \(total.formattedSize). You can restore from Trash if needed."
    }

    private func performTrash(infos: [FileNodeInfo]) {
        Task {
            let manager = TrashManager()
            var removed: [UInt32] = []
            var firstError: String?
            for info in infos {
                let url = URL(fileURLWithPath: info.fullPath)
                do {
                    _ = try await manager.moveToTrash(url: url)
                    removed.append(info.id)
                } catch let trashErr as TrashError {
                    // "File not found" means the file is already gone on
                    // disk — drop the row from the list anyway since
                    // keeping it visible misleads the user.
                    if case .fileNotFound = trashErr {
                        removed.append(info.id)
                    } else if firstError == nil {
                        firstError = trashErr.errorDescription ?? "Failed to move to Trash"
                    }
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
            if !removed.isEmpty {
                viewModel.files.removeAll { removed.contains($0.id) }
                viewModel.selectedFiles.subtract(removed)
                onFilesTrashed?(removed)
            }
            if let firstError {
                trashError = firstError
                showTrashError = true
            }
        }
        trashTargetInfos = []
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Mode picker
            Menu {
                Section("Top N") {
                    ForEach(LargeFilesMode.topNPresets, id: \.displayName) { mode in
                        Button(mode.displayName) {
                            viewModel.mode = mode
                            refreshData()
                        }
                    }
                }
                Section("Threshold") {
                    ForEach(LargeFilesMode.thresholdPresets, id: \.displayName) { mode in
                        Button(mode.displayName) {
                            viewModel.mode = mode
                            refreshData()
                        }
                    }
                }
            } label: {
                Label(viewModel.mode.displayName, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.callout)
            }

            Spacer()

            // File count
            Text("\(viewModel.filteredFiles.count) files")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Search
            TextField("Search files...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            // Add to Drop Zone
            if let dropZone = dropZoneViewModel, !viewModel.selectedFiles.isEmpty {
                Button {
                    addSelectionToDropZone(dropZone)
                } label: {
                    Label("Add to Drop Zone", systemImage: "trash")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: File Table

    private var fileTable: some View {
        Table(viewModel.filteredFiles, selection: $viewModel.selectedFiles) {
            TableColumn("Name") { file in
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: file))
                        .foregroundStyle(SpacieColors.color(for: file.fileType))
                        .frame(width: 16)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 200, ideal: 300)

            TableColumn("Size") { file in
                Text(file.logicalSize.formattedSize)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Path") { file in
                Text(abbreviatedPath(file.fullPath))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.fullPath)
            }
            .width(min: 150, ideal: 250)

            TableColumn("Modified") { file in
                Text(file.modificationDate, style: .date)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Type") { file in
                Text(file.fileType.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: UInt32.self) { selectedIds in
            contextMenuContent(for: selectedIds)
        } primaryAction: { selectedIds in
            // Double-click: Quick Look
            if let firstId = selectedIds.first,
               let file = viewModel.files.first(where: { $0.id == firstId }) {
                quickLookURL = URL(fileURLWithPath: file.fullPath)
            }
        }
        .onKeyPress(.space) {
            if let firstId = viewModel.selectedFiles.first,
               let file = viewModel.files.first(where: { $0.id == firstId }) {
                quickLookURL = URL(fileURLWithPath: file.fullPath)
                return .handled
            }
            return .ignored
        }
    }

    // MARK: Context Menu

    @ViewBuilder
    private func contextMenuContent(for ids: Set<UInt32>) -> some View {
        let selectedInfos = viewModel.files.filter { ids.contains($0.id) }

        Button("Reveal in Finder") {
            let urls = selectedInfos.map { URL(fileURLWithPath: $0.fullPath) }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        Button("Quick Look") {
            if let first = selectedInfos.first {
                quickLookURL = URL(fileURLWithPath: first.fullPath)
            }
        }

        Divider()

        Button("Copy Path") {
            let paths = selectedInfos.map(\.fullPath).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
        }

        Button("Copy Name") {
            let names = selectedInfos.map(\.name).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(names, forType: .string)
        }

        Divider()

        Button("Move to Trash", role: .destructive) {
            trashTargetInfos = selectedInfos
            showTrashConfirm = true
        }
        .keyboardShortcut(.delete, modifiers: .command)

        Divider()

        if let dropZone = dropZoneViewModel {
            Button("Add to Drop Zone") {
                for info in selectedInfos {
                    dropZone.addItem(info)
                }
            }
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No large files found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Try adjusting the threshold or scanning a different volume.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status Bar

    private var statusBar: some View {
        HStack {
            Text(viewModel.selectionSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Helpers

    private func refreshData() {
        if let tree {
            viewModel.refresh(tree: tree, sizeMode: sizeMode)
        }
    }

    private func addSelectionToDropZone(_ dropZone: DropZoneViewModel) {
        for info in viewModel.selectedFileInfos {
            dropZone.addItem(info)
        }
    }

    private func iconName(for file: FileNodeInfo) -> String {
        if file.isDirectory { return "folder.fill" }
        switch file.fileType {
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

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Preview

#Preview("Large Files") {
    LargeFilesView(viewModel: LargeFilesViewModel())
        .frame(width: 800, height: 500)
}

// MARK: - ContentStateView (shared 3-state container)

/// Three-state container used across feature views to enforce
/// `loading | empty | content` rendering. Placed here (rather than its own
/// file) because the Xcode project does not auto-discover new files in
/// `Shared/`. Used by `LargeFilesView`, `OldFilesView`, `StorageBrowserView`.
struct ContentStateView<Content: View>: View {

    let isLoading: Bool
    let isEmpty: Bool
    let loadingTitle: String
    let loadingSubtitle: String?
    let emptyIcon: String
    let emptyTitle: String
    let emptyMessage: String?
    @ViewBuilder let content: () -> Content

    init(
        isLoading: Bool,
        isEmpty: Bool,
        loadingTitle: String = "Loading…",
        loadingSubtitle: String? = nil,
        emptyIcon: String = "tray",
        emptyTitle: String = "No items",
        emptyMessage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isLoading = isLoading
        self.isEmpty = isEmpty
        self.loadingTitle = loadingTitle
        self.loadingSubtitle = loadingSubtitle
        self.emptyIcon = emptyIcon
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.content = content
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 14) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.large)
                Text(loadingTitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if let subtitle = loadingSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if isEmpty {
            ContentUnavailableView(
                emptyTitle,
                systemImage: emptyIcon,
                description: emptyMessage.map(Text.init)
            )
        } else {
            content()
        }
    }
}

struct InlineLoadingBar: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().progressViewStyle(.circular).controlSize(.small)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}
