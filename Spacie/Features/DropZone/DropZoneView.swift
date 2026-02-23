import SwiftUI
import UniformTypeIdentifiers

// MARK: - DropZoneItem

struct DropZoneItem: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let size: UInt64
    let fileType: FileType
    let isDirectory: Bool
    let blocklistStatus: BlocklistStatus

    enum BlocklistStatus: Sendable, Hashable {
        case allowed
        case warning(reason: String)
        case blocked(reason: String)
    }

    var url: URL { URL(fileURLWithPath: path) }
    var formattedSize: String { size.formattedSize }

    var systemImage: String {
        if case .blocked = blocklistStatus { return "lock.fill" }
        if isDirectory { return "folder.fill" }
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DropZoneItem, rhs: DropZoneItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DropZoneViewModel

@MainActor
@Observable
final class DropZoneViewModel {

    // MARK: Published State

    var items: [DropZoneItem] = []
    var isDropTargeted: Bool = false
    var lastWarningMessage: String?
    var showWarningOverlay: Bool = false

    // MARK: Computed

    var totalSize: UInt64 {
        items.reduce(0) { $0 + $1.size }
    }

    var itemCountText: String {
        let count = items.count
        let size = totalSize.formattedSize
        if count == 0 { return "" }
        let itemWord = count == 1 ? "item" : "items"
        return "\(count) \(itemWord), \(size)"
    }

    var isEmpty: Bool { items.isEmpty }

    var hasWarningItems: Bool {
        items.contains { item in
            if case .warning = item.blocklistStatus { return true }
            return false
        }
    }

    // MARK: Undo

    private weak var undoManager: UndoManager?

    func setUndoManager(_ manager: UndoManager?) {
        self.undoManager = manager
    }

    // MARK: Actions

    /// Adds a FileNodeInfo to the drop zone after checking the blocklist.
    /// Returns false if the item is blocked.
    @discardableResult
    func addItem(_ info: FileNodeInfo) -> Bool {
        let permission = BlocklistManager.checkPermission(for: info.fullPath)

        let status: DropZoneItem.BlocklistStatus
        switch permission {
        case .allowed:
            status = .allowed
        case .warning(let reason):
            status = .warning(reason: reason)
            lastWarningMessage = reason
            showWarningOverlay = true
        case .blocked(let reason):
            lastWarningMessage = reason
            showWarningOverlay = true
            return false
        }

        // Prevent duplicates by path
        guard !items.contains(where: { $0.path == info.fullPath }) else { return true }

        let item = DropZoneItem(
            id: UUID(),
            name: info.name,
            path: info.fullPath,
            size: info.logicalSize,
            fileType: info.fileType,
            isDirectory: info.isDirectory,
            blocklistStatus: status
        )

        items.append(item)
        registerUndoForAdd(item)
        return true
    }

    /// Adds an item directly from a file URL (e.g., from system drag-and-drop).
    @discardableResult
    func addItem(from url: URL) -> Bool {
        let path = url.path
        let permission = BlocklistManager.checkPermission(for: path)

        let status: DropZoneItem.BlocklistStatus
        switch permission {
        case .allowed:
            status = .allowed
        case .warning(let reason):
            status = .warning(reason: reason)
            lastWarningMessage = reason
            showWarningOverlay = true
        case .blocked(let reason):
            lastWarningMessage = reason
            showWarningOverlay = true
            return false
        }

        guard !items.contains(where: { $0.path == path }) else { return true }

        let fm = FileManager.default
        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey, .isDirectoryKey, .contentModificationDateKey
        ])
        let fileSize = UInt64(resourceValues?.fileSize ?? 0)
        let isDir = resourceValues?.isDirectory ?? false
        let ext = url.pathExtension
        let fileType = FileType.from(extension: ext)

        // If directory, compute total size
        var totalSize = fileSize
        if isDir {
            totalSize = (try? fm.allocatedSizeOfDirectory(at: url)) ?? fileSize
        }

        let item = DropZoneItem(
            id: UUID(),
            name: url.lastPathComponent,
            path: path,
            size: totalSize,
            fileType: isDir ? .other : fileType,
            isDirectory: isDir,
            blocklistStatus: status
        )

        items.append(item)
        registerUndoForAdd(item)
        return true
    }

    func removeItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        registerUndoForRemove(removed, at: index)
    }

    func moveAllToTrash() async throws {
        let itemsToTrash = items
        var errors: [(String, Error)] = []

        for item in itemsToTrash {
            do {
                var resultURL: NSURL?
                try FileManager.default.trashItem(
                    at: item.url,
                    resultingItemURL: &resultURL
                )
            } catch {
                errors.append((item.path, error))
            }
        }

        // Remove successfully trashed items
        let failedPaths = Set(errors.map(\.0))
        items.removeAll { !failedPaths.contains($0.path) }

        if !errors.isEmpty {
            let descriptions = errors.map { "\($0.0): \($0.1.localizedDescription)" }
            throw DropZoneError.trashFailed(descriptions)
        }
    }

    func clear() {
        items.removeAll()
        showWarningOverlay = false
        lastWarningMessage = nil
    }

    func dismissWarning() {
        showWarningOverlay = false
        lastWarningMessage = nil
    }

    // MARK: Undo Registration

    private func registerUndoForAdd(_ item: DropZoneItem) {
        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            self?.items.removeAll { $0.id == item.id }
        }
        undoManager?.setActionName("Add to Drop Zone")
    }

    private func registerUndoForRemove(_ item: DropZoneItem, at index: Int) {
        undoManager?.registerUndo(withTarget: UndoTarget.shared) { [weak self] _ in
            guard let self else { return }
            let safeIndex = min(index, self.items.count)
            self.items.insert(item, at: safeIndex)
        }
        undoManager?.setActionName("Remove from Drop Zone")
    }
}

// MARK: - DropZoneError

enum DropZoneError: LocalizedError {
    case trashFailed([String])

    var errorDescription: String? {
        switch self {
        case .trashFailed(let descriptions):
            return "Failed to move some items to Trash:\n" + descriptions.joined(separator: "\n")
        }
    }
}

/// Helper class for UndoManager target (needs to be a reference type).
private final class UndoTarget: @unchecked Sendable {
    static let shared = UndoTarget()
    private init() {}
}

// MARK: - DropZoneView

struct DropZoneView: View {
    @Bindable var viewModel: DropZoneViewModel
    @Environment(\.undoManager) private var undoManager
    @State private var isTrashInProgress = false
    @State private var trashError: String?
    @State private var showTrashConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isEmpty {
                emptyStateView
            } else {
                contentView
            }
        }
        .background(dropZoneBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    viewModel.isDropTargeted ? SpacieColors.dropZoneBorder : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            handleDrop(providers)
        }
        .onAppear {
            viewModel.setUndoManager(undoManager)
        }
        .onChange(of: undoManager) { _, newValue in
            viewModel.setUndoManager(newValue)
        }
        .overlay(alignment: .top) {
            warningOverlayView
        }
        .alert("Move to Trash", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                performTrash()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Move \(viewModel.items.count) items (\(viewModel.totalSize.formattedSize)) to Trash?")
        }
        .alert("Trash Error", isPresented: .init(
            get: { trashError != nil },
            set: { if !$0 { trashError = nil } }
        )) {
            Button("OK") { trashError = nil }
        } message: {
            if let error = trashError {
                Text(error)
            }
        }
    }

    // MARK: Empty State

    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "trash.slash")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Drag files here to delete")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }

    // MARK: Content View

    private var contentView: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.items) { item in
                        DropZoneItemCard(item: item) {
                            viewModel.removeItem(id: item.id)
                        }
                        .draggable(item.url.absoluteString) {
                            DropZoneItemCard(item: item, onRemove: {})
                                .frame(width: 100, height: 70)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            VStack(spacing: 8) {
                Text(viewModel.itemCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    showTrashConfirmation = true
                } label: {
                    Label("Move to Trash", systemImage: "trash.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isTrashInProgress)

                if isTrashInProgress {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Clear") {
                    viewModel.clear()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.trailing, 12)
        }
    }

    // MARK: Warning Overlay

    @ViewBuilder
    private var warningOverlayView: some View {
        if viewModel.showWarningOverlay, let message = viewModel.lastWarningMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SpacieColors.warningForeground)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    viewModel.dismissWarning()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(SpacieColors.warningBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Background

    private var dropZoneBackground: some ShapeStyle {
        viewModel.isDropTargeted
            ? AnyShapeStyle(SpacieColors.dropZoneActive)
            : AnyShapeStyle(SpacieColors.dropZoneBackground)
    }

    // MARK: Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var didAdd = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    if viewModel.addItem(from: url) {
                        didAdd = true
                    }
                }
            }
        }
        return true
    }

    // MARK: Trash Execution

    private func performTrash() {
        isTrashInProgress = true
        Task {
            do {
                try await viewModel.moveAllToTrash()
            } catch {
                trashError = error.localizedDescription
            }
            isTrashInProgress = false
        }
    }
}

// MARK: - DropZoneItemCard

struct DropZoneItemCard: View {
    let item: DropZoneItem
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)

                if isHovered {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .background(Circle().fill(.gray))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 80)

            Text(item.formattedSize)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if case .warning = item.blocklistStatus {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(SpacieColors.warningForeground)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("Remove from Drop Zone") {
                onRemove()
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }

    private var iconColor: Color {
        switch item.blocklistStatus {
        case .blocked:  return .gray
        case .warning:  return SpacieColors.warningForeground
        case .allowed:  return SpacieColors.color(for: item.fileType)
        }
    }
}

// MARK: - Preview

#Preview("Drop Zone - Empty") {
    DropZoneView(viewModel: DropZoneViewModel())
        .frame(height: 100)
        .padding()
}

#Preview("Drop Zone - With Items") {
    let vm = DropZoneViewModel()
    let _ = vm.items = [
        DropZoneItem(id: UUID(), name: "Movie.mp4", path: "/Users/test/Movie.mp4", size: 5_000_000_000, fileType: .video, isDirectory: false, blocklistStatus: .allowed),
        DropZoneItem(id: UUID(), name: "Archive", path: "/Users/test/Archive", size: 4_000_000_000, fileType: .other, isDirectory: true, blocklistStatus: .allowed),
        DropZoneItem(id: UUID(), name: ".zshrc", path: "/Users/test/.zshrc", size: 2048, fileType: .code, isDirectory: false, blocklistStatus: .warning(reason: "This file may be important.")),
    ]
    return DropZoneView(viewModel: vm)
        .frame(height: 120)
        .padding()
}
