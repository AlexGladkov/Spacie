import SwiftUI

// MARK: - FileType Extensions

extension FileType {
    /// SF Symbol icon name for this file type.
    var icon: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .application: "app.badge"
        case .system: "gearshape"
        case .other: "questionmark.square"
        }
    }
}

// MARK: - StorageBrowserView

/// Split-layout browser: folder/file list on the left, file type distribution on the right.
struct StorageBrowserView: View {
    let tree: FileTree
    @Bindable var state: VisualizationState
    let sizeMode: SizeMode

    var body: some View {
        HStack(spacing: 0) {
            FolderListPanel(tree: tree, state: state, sizeMode: sizeMode)

            Divider()

            FileTypePanel(
                tree: tree,
                rootIndex: state.currentRootIndex,
                sizeMode: sizeMode,
                useEntryCount: state.useEntryCount
            )
            .frame(width: 320)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - FolderListPanel

/// Left panel showing children of the current root sorted by size (or entry count during Yellow phase).
private struct FolderListPanel: View {
    let tree: FileTree
    @Bindable var state: VisualizationState
    let sizeMode: SizeMode

    private var useEntryCount: Bool { state.useEntryCount }

    var body: some View {
        let children = sortedChildren()
        let parentValue = computeParentValue()

        List {
            ForEach(children, id: \.self) { index in
                FolderRow(
                    tree: tree,
                    index: index,
                    parentValue: parentValue,
                    sizeMode: sizeMode,
                    useEntryCount: useEntryCount
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    revealInFinder(index: index)
                }
                .onTapGesture {
                    let node = tree[index]
                    if node.isDirectory && !node.isVirtual {
                        state.drillDown(to: index)
                    }
                }
                .contextMenu {
                    Button("Reveal in Finder") {
                        revealInFinder(index: index)
                    }
                    Button("Copy Path") {
                        let path = tree.fullPath(of: index)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func sortedChildren() -> [UInt32] {
        if useEntryCount {
            return tree.children(of: state.currentRootIndex)
                .sorted { tree.entryCount(of: $0) > tree.entryCount(of: $1) }
        } else {
            return tree.sortedChildren(of: state.currentRootIndex, by: .sizeDescending)
        }
    }

    private func computeParentValue() -> UInt64 {
        if useEntryCount {
            return UInt64(tree.entryCount(of: state.currentRootIndex))
        } else {
            return tree.size(of: state.currentRootIndex, mode: sizeMode)
        }
    }

    private func revealInFinder(index: UInt32) {
        let path = tree.fullPath(of: index)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

// MARK: - FolderRow

/// A single row showing icon, name, size, and proportional bar for one child node.
private struct FolderRow: View {
    let tree: FileTree
    let index: UInt32
    let parentValue: UInt64
    let sizeMode: SizeMode
    let useEntryCount: Bool

    var body: some View {
        let node = tree[index]
        let name = tree.name(of: index)
        let value: UInt64 = useEntryCount
            ? UInt64(tree.entryCount(of: index))
            : tree.size(of: index, mode: sizeMode)
        let fraction = parentValue > 0 ? Double(value) / Double(parentValue) : 0

        HStack(spacing: 8) {
            // Icon
            Image(systemName: node.isDirectory ? "folder.fill" : node.fileType.icon)
                .foregroundStyle(node.isDirectory ? Color.blue : SpacieColors.color(for: node.fileType))
                .frame(width: 20, alignment: .center)

            // Name
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Size / entry count
            Text(useEntryCount ? "\(value.formattedCount) items" : value.formattedSize)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)

            // Proportional bar
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(node: node))
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
            .frame(width: 80, height: 12)
        }
        .padding(.vertical, 2)
    }

    private func barColor(node: FileNode) -> Color {
        if node.isDirectory {
            return Color.blue.opacity(0.3)
        }
        return SpacieColors.color(for: node.fileType).opacity(0.3)
    }
}

// MARK: - FileTypePanel

/// Right panel showing file type distribution as a donut chart with legend.
private struct FileTypePanel: View {
    let tree: FileTree
    let rootIndex: UInt32
    let sizeMode: SizeMode
    let useEntryCount: Bool

    @State private var distribution: [TypeEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            if useEntryCount {
                yellowPhasePlaceholder
            } else if distribution.isEmpty {
                emptyPlaceholder
            } else {
                donutChart
                    .padding(20)

                Divider()

                legend
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: distributionTaskKey) {
            if !useEntryCount {
                distribution = buildDistribution()
            } else {
                distribution = []
            }
        }
    }

    private var distributionTaskKey: String {
        "\(rootIndex)-\(sizeMode.rawValue)-\(useEntryCount)-\(tree.size(of: rootIndex, mode: sizeMode))"
    }

    // MARK: - Donut Chart

    private var donutChart: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let outerRadius = size / 2 * 0.85
            let innerRadius = outerRadius * 0.55
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let slices = buildSlices(from: distribution)

            ZStack {
                ForEach(slices) { slice in
                    FileTypeDonutSlice(
                        center: center,
                        innerRadius: innerRadius,
                        outerRadius: outerRadius,
                        startAngle: slice.startAngle,
                        endAngle: slice.endAngle
                    )
                    .fill(slice.color)
                    .overlay {
                        FileTypeDonutSlice(
                            center: center,
                            innerRadius: innerRadius,
                            outerRadius: outerRadius,
                            startAngle: slice.startAngle,
                            endAngle: slice.endAngle
                        )
                        .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5)
                    }
                }

                // Center label
                VStack(spacing: 4) {
                    let totalSize = distribution.reduce(UInt64(0)) { $0 + $1.size }
                    Text(totalSize.formattedSize)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("\(distribution.count) types")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .position(center)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Legend

    private var legend: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(distribution) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SpacieColors.color(for: entry.type))
                            .frame(width: 10, height: 10)

                        Text(entry.type.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)

                        Spacer()

                        Text("\(Int(entry.fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Text(entry.size.formattedSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Placeholders

    private var yellowPhasePlaceholder: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 8, height: 8)
                Text("Approximate Data")
                    .font(.headline)
            }
            Text("File type distribution will appear when deep scan completes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyPlaceholder: some View {
        ContentUnavailableView(
            "No file data",
            systemImage: "chart.pie",
            description: Text("No files found in this directory")
        )
    }

    // MARK: - Distribution Computation

    private func buildDistribution() -> [TypeEntry] {
        var buckets = [UInt64](repeating: 0, count: FileType.allCases.count)

        var stack: [UInt32] = tree.children(of: rootIndex)
        while let index = stack.popLast() {
            guard let node = tree.node(at: index) else { continue }
            if !node.isDirectory {
                switch sizeMode {
                case .logical:  buckets[Int(node.fileType.rawValue)] += node.logicalSize
                case .physical: buckets[Int(node.fileType.rawValue)] += node.physicalSize
                }
            }
            if node.isDirectory {
                stack.append(contentsOf: tree.children(of: index))
            }
        }

        let total = buckets.reduce(UInt64(0), +)
        guard total > 0 else { return [] }

        return FileType.allCases.compactMap { type -> TypeEntry? in
            let size = buckets[Int(type.rawValue)]
            guard size > 0 else { return nil }
            return TypeEntry(type: type, size: size, fraction: Double(size) / Double(total))
        }
        .sorted { $0.size > $1.size }
    }

    // MARK: - Slice Building

    private func buildSlices(from entries: [TypeEntry]) -> [FileTypeSlice] {
        var slices: [FileTypeSlice] = []
        var angle: Double = -.pi / 2

        for entry in entries {
            let sweep = entry.fraction * 2 * .pi
            slices.append(FileTypeSlice(
                id: entry.type.rawValue,
                startAngle: angle,
                endAngle: angle + sweep,
                color: SpacieColors.color(for: entry.type)
            ))
            angle += sweep
        }

        return slices
    }
}

// MARK: - Supporting Types

private struct TypeEntry: Identifiable, Sendable {
    let type: FileType
    let size: UInt64
    let fraction: Double

    var id: UInt8 { type.rawValue }
}

private struct FileTypeSlice: Identifiable {
    let id: UInt8
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

// MARK: - Donut Slice Shape

private struct FileTypeDonutSlice: Shape {
    let center: CGPoint
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let startAngle: Double
    let endAngle: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = Angle(radians: startAngle)
        let end = Angle(radians: endAngle)

        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()

        return path
    }
}
