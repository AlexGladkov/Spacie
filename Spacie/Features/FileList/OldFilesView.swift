import SwiftUI
import QuickLook

// MARK: - AgePreset

enum AgePreset: String, CaseIterable, Identifiable, Sendable {
    case sixMonths = "6 months"
    case oneYear = "1 year"
    case twoYears = "2 years"

    var id: String { rawValue }

    var timeInterval: TimeInterval {
        switch self {
        case .sixMonths: return 6 * 30 * 86400    // ~180 days
        case .oneYear:   return 365 * 86400        // 365 days
        case .twoYears:  return 2 * 365 * 86400    // 730 days
        }
    }

    var displayName: String {
        switch self {
        case .sixMonths: "Older than 6 months"
        case .oneYear:   "Older than 1 year"
        case .twoYears:  "Older than 2 years"
        }
    }
}

// MARK: - OldFilesViewModel

@MainActor
@Observable
final class OldFilesViewModel {

    // MARK: State

    var agePreset: AgePreset = .oneYear
    var files: [FileNodeInfo] = []
    var sortOrder: SortOrder = SortOrder(field: .date, ascending: true)
    var selectedFiles: Set<UInt32> = []
    var searchText: String = ""
    var isRefreshing: Bool = false

    // MARK: Computed

    var ageThreshold: TimeInterval {
        agePreset.timeInterval
    }

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

    var totalSize: UInt64 {
        files.reduce(0) { $0 + $1.logicalSize }
    }

    var selectedFileInfos: [FileNodeInfo] {
        files.filter { selectedFiles.contains($0.id) }
    }

    // MARK: Actions

    func refresh(tree: FileTree) {
        isRefreshing = true
        defer { isRefreshing = false }

        let cutoff = Date().addingTimeInterval(-ageThreshold)
        var result: [FileNodeInfo] = []

        for i in 0..<UInt32(tree.nodeCount) {
            let node = tree[i]
            // Skip directories and symlinks
            guard !node.isDirectory, !node.isSymlink else { continue }
            // Skip zero-size files
            guard node.logicalSize > 0 else { continue }

            let modDate = node.modificationDate
            if modDate < cutoff {
                result.append(tree.nodeInfo(at: i))
            }
        }

        files = result

        // Clear stale selections
        let validIds = Set(files.map(\.id))
        selectedFiles = selectedFiles.intersection(validIds)
    }

    func setAgePreset(_ preset: AgePreset, tree: FileTree?) {
        agePreset = preset
        if let tree {
            refresh(tree: tree)
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
}

// MARK: - OldFilesView

struct OldFilesView: View {
    @Bindable var viewModel: OldFilesViewModel
    var dropZoneViewModel: DropZoneViewModel?
    var tree: FileTree?

    @State private var quickLookURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.filteredFiles.isEmpty {
                emptyState
            } else {
                fileTable
            }
            if !viewModel.selectionSummary.isEmpty || !viewModel.files.isEmpty {
                statusBar
            }
        }
        .quickLookPreview($quickLookURL)
        .onAppear {
            if let tree {
                viewModel.refresh(tree: tree)
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Age preset picker
            Picker("Age", selection: $viewModel.agePreset) {
                ForEach(AgePreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 500)
            .onChange(of: viewModel.agePreset) { _, newPreset in
                viewModel.setAgePreset(newPreset, tree: tree)
            }

            Spacer()

            Text("\(viewModel.filteredFiles.count) files")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Search files...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

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
            .width(min: 180, ideal: 250)

            TableColumn("Last Modified") { file in
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.modificationDate, style: .date)
                        .font(.callout)
                    Text(ageDescription(for: file.modificationDate))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 120, ideal: 150)

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
            Image(systemName: "clock.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No old files found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No files are older than the selected threshold.")
                .font(.callout)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Status Bar

    private var statusBar: some View {
        HStack {
            if !viewModel.selectionSummary.isEmpty {
                Text(viewModel.selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Total: \(viewModel.files.count) files, \(viewModel.totalSize.formattedSize)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Helpers

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

    private func ageDescription(for date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86400)
        if days < 30 {
            return "\(days) days ago"
        } else if days < 365 {
            let months = days / 30
            return "\(months) month\(months == 1 ? "" : "s") ago"
        } else {
            let years = days / 365
            let remainingMonths = (days % 365) / 30
            if remainingMonths > 0 {
                return "\(years)y \(remainingMonths)m ago"
            }
            return "\(years) year\(years == 1 ? "" : "s") ago"
        }
    }
}

// MARK: - Preview

#Preview("Old Files") {
    OldFilesView(viewModel: OldFilesViewModel())
        .frame(width: 800, height: 500)
}
