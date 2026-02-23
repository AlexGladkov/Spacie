import SwiftUI

// MARK: - SmartCategoriesViewModel

@MainActor
@Observable
final class SmartCategoriesViewModel {

    // MARK: State

    var categories: [CategoryResult] = []
    var isScanning: Bool = false
    var selectedItems: Set<String> = []
    var expandedCategoryId: String?
    var searchText: String = ""

    // MARK: Dependencies

    private let pluginManager: PluginManager

    // MARK: Init

    init(pluginManager: PluginManager = .shared) {
        self.pluginManager = pluginManager
    }

    // MARK: Computed

    var totalCleanableSize: UInt64 {
        categories.reduce(0) { $0 + $1.totalSize }
    }

    var availableCategories: [CategoryResult] {
        let results = categories.filter { $0.isAvailable && $0.totalSize > 0 }
        if searchText.isEmpty {
            return results
        }
        let query = searchText.lowercased()
        return results.filter {
            String(localized: $0.category.name).lowercased().contains(query)
        }
    }

    var selectedItemsSize: UInt64 {
        var size: UInt64 = 0
        for category in categories {
            for item in category.items where selectedItems.contains(item.id) {
                size += item.size
            }
        }
        return size
    }

    var selectedItemsCount: Int {
        selectedItems.count
    }

    // MARK: Actions

    func scan() async {
        isScanning = true
        defer { isScanning = false }

        if pluginManager.allCategories.isEmpty {
            pluginManager.registerBuiltIn()
        }

        let results = await pluginManager.scanAll()
        categories = results
    }

    func toggleItemSelection(_ itemId: String) {
        if selectedItems.contains(itemId) {
            selectedItems.remove(itemId)
        } else {
            selectedItems.insert(itemId)
        }
    }

    func selectAllSafe() async {
        selectedItems.removeAll()
        for category in categories {
            for item in category.items {
                let safe = await category.category.canSafelyDelete(item: item.url)
                if safe {
                    selectedItems.insert(item.id)
                }
            }
        }
    }

    func selectAllInCategory(_ categoryId: String) {
        guard let category = categories.first(where: { $0.id == categoryId }) else { return }
        for item in category.items {
            selectedItems.insert(item.id)
        }
    }

    func deselectAllInCategory(_ categoryId: String) {
        guard let category = categories.first(where: { $0.id == categoryId }) else { return }
        for item in category.items {
            selectedItems.remove(item.id)
        }
    }

    func sendToDropZone(dropZone: DropZoneViewModel) {
        for category in categories {
            for item in category.items where selectedItems.contains(item.id) {
                let info = FileNodeInfo(
                    id: 0,
                    name: item.name,
                    fullPath: item.url.path,
                    logicalSize: item.size,
                    physicalSize: item.size,
                    isDirectory: item.isDirectory,
                    fileType: item.isDirectory ? .other : FileType.from(extension: item.url.pathExtension),
                    modificationDate: item.modificationDate ?? Date.distantPast,
                    childCount: 0,
                    depth: 0,
                    flags: FileNodeFlags(rawValue: 0)
                )
                dropZone.addItem(info)
            }
        }
    }
}

// MARK: - SmartCategoriesView

struct SmartCategoriesView: View {
    @Bindable var viewModel: SmartCategoriesViewModel
    var dropZoneViewModel: DropZoneViewModel?

    @State private var columns = [
        GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if viewModel.isScanning {
                scanningView
            } else if viewModel.categories.isEmpty {
                emptyView
            } else if viewModel.expandedCategoryId != nil {
                categoryDetailView
            } else {
                categoryGridView
            }

            if viewModel.selectedItemsCount > 0 {
                actionBar
            }
        }
    }

    // MARK: Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Categories")
                    .font(.headline)
                if !viewModel.categories.isEmpty {
                    Text("Total: \(viewModel.totalCleanableSize.formattedSize)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !viewModel.categories.isEmpty {
                TextField("Search...", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)

                Button("Clean All Safe") {
                    Task { await viewModel.selectAllSafe() }
                }
                .help("Select all items that are safe to delete")
            }

            Button {
                Task { await viewModel.scan() }
            } label: {
                Label(
                    viewModel.categories.isEmpty ? "Scan" : "Rescan",
                    systemImage: "magnifyingglass"
                )
            }
            .disabled(viewModel.isScanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Scanning categories...")
                .font(.headline)
            Text("Checking caches, logs, and development tools")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Empty

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Smart Cleanup")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Click Scan to find caches, logs, developer tools, and other cleanable items.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Category Grid

    private var categoryGridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(viewModel.availableCategories) { result in
                    CategoryCard(result: result) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.expandedCategoryId = result.id
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: Category Detail

    @ViewBuilder
    private var categoryDetailView: some View {
        if let categoryId = viewModel.expandedCategoryId,
           let result = viewModel.categories.first(where: { $0.id == categoryId }) {
            VStack(spacing: 0) {
                // Back bar
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.expandedCategoryId = nil
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Image(systemName: result.category.icon)
                        .foregroundStyle(.secondary)

                    Text(String(localized: result.category.name))
                        .font(.callout.weight(.semibold))

                    Text("(\(result.totalSize.formattedSize))")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Select All") {
                        viewModel.selectAllInCategory(categoryId)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)

                    Button("Deselect All") {
                        viewModel.deselectAllInCategory(categoryId)
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

                Divider()

                // Item list
                List {
                    ForEach(result.items) { item in
                        CategoryItemRow(
                            item: item,
                            isSelected: viewModel.selectedItems.contains(item.id),
                            onToggle: { viewModel.toggleItemSelection(item.id) }
                        )
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }

    // MARK: Action Bar

    private var actionBar: some View {
        HStack {
            Text("\(viewModel.selectedItemsCount) items selected (\(viewModel.selectedItemsSize.formattedSize))")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            if let dropZone = dropZoneViewModel {
                Button {
                    viewModel.sendToDropZone(dropZone: dropZone)
                } label: {
                    Label("Clean Selected", systemImage: "trash")
                        .font(.callout.weight(.semibold))
                }
                .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - CategoryCard

struct CategoryCard: View {
    let result: CategoryResult
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: result.category.icon)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)

                    Spacer()

                    sizeBadge
                }

                Text(String(localized: result.category.name))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(String(localized: result.category.description))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)

                HStack {
                    Text("\(result.itemCount) items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(result.displaySize)
                        .font(.callout.weight(.medium).monospacedDigit())
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 6 : 3, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var sizeBadge: some View {
        let size = result.totalSize
        if size > 10_000_000_000 { // > 10 GB
            badgeView(text: "> 10 GB", color: .red)
        } else if size > 1_000_000_000 { // > 1 GB
            badgeView(text: "> 1 GB", color: .orange)
        }
    }

    private func badgeView(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

// MARK: - CategoryItemRow

struct CategoryItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(
                get: { isSelected },
                set: { _ in onToggle() }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .frame(width: 16)

            Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(abbreviatedPath(item.url.path))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let date = item.modificationDate {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Text(item.size.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
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

#Preview("Smart Categories - Empty") {
    SmartCategoriesView(viewModel: SmartCategoriesViewModel())
        .frame(width: 700, height: 500)
}
