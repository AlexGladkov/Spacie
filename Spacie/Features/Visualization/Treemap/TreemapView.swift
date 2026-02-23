import SwiftUI

// MARK: - Squarified Treemap Layout Builder

/// Builds a flat array of `RectSegment` using the squarified treemap algorithm
/// (Bruls, Huizing, van Wijk, 2000). The algorithm optimizes aspect ratios of
/// rectangles by laying items out in rows, choosing the orientation (horizontal
/// or vertical) that minimizes the worst aspect ratio in each row.
///
/// - Parameters:
///   - tree: The file tree data source.
///   - rootIndex: The tree index of the current visualization root.
///   - sizeMode: Whether to use logical or physical sizes.
///   - rect: The bounding rectangle to fill.
///   - maxDepth: Maximum nesting depth to render (default 3).
/// - Returns: An array of `RectSegment` for all visible rectangles.
func buildTreemapLayout(
    tree: FileTree,
    rootIndex: UInt32,
    sizeMode: SizeMode,
    rect: CGRect,
    maxDepth: Int = VisualizationConstants.treemapMaxDepth
) -> [RectSegment] {
    var segments: [RectSegment] = []
    let rootSize = tree.size(of: rootIndex, mode: sizeMode)
    guard rootSize > 0, rect.width > 0, rect.height > 0 else { return segments }

    layoutNode(
        tree: tree,
        nodeIndex: rootIndex,
        sizeMode: sizeMode,
        rect: rect,
        depth: 0,
        maxDepth: maxDepth,
        totalParentSize: rootSize,
        segments: &segments
    )

    return segments
}

/// Recursively lays out a single node and its children using the squarified algorithm.
private func layoutNode(
    tree: FileTree,
    nodeIndex: UInt32,
    sizeMode: SizeMode,
    rect: CGRect,
    depth: Int,
    maxDepth: Int,
    totalParentSize: UInt64,
    segments: inout [RectSegment]
) {
    let nodeSize = tree.size(of: nodeIndex, mode: sizeMode)
    guard nodeSize > 0, rect.width >= 1, rect.height >= 1 else { return }

    let nodeInfo = tree.nodeInfo(at: nodeIndex)

    // Add segment for this node at depth > 0 (depth 0 is the root container itself).
    if depth > 0 {
        let segment = RectSegment(
            id: nodeIndex,
            name: nodeInfo.name,
            size: nodeSize,
            fileType: nodeInfo.fileType,
            depth: depth,
            rect: rect,
            childrenCount: nodeInfo.childCount,
            isDirectory: nodeInfo.isDirectory
        )
        segments.append(segment)
    }

    // Recurse into children if this is a directory and we have depth budget.
    guard nodeInfo.isDirectory, depth < maxDepth else { return }

    let childIndices = tree.sortedChildren(of: nodeIndex, by: .size)
    guard !childIndices.isEmpty else { return }

    // Gather children with their sizes, filtering out zero-size.
    struct ChildEntry {
        let index: UInt32
        let size: UInt64
    }

    let children: [ChildEntry] = childIndices.compactMap { index in
        let size = tree.size(of: index, mode: sizeMode)
        return size > 0 ? ChildEntry(index: index, size: size) : nil
    }

    guard !children.isEmpty else { return }

    // Inset rect slightly for nested directories to create visual nesting.
    let inset: CGFloat = depth > 0 ? VisualizationConstants.treemapBorderWidth : 0
    let headerHeight: CGFloat = depth > 0 ? 18 : 0
    let innerRect = CGRect(
        x: rect.minX + inset,
        y: rect.minY + inset + headerHeight,
        width: max(0, rect.width - inset * 2),
        height: max(0, rect.height - inset * 2 - headerHeight)
    )

    guard innerRect.width >= 2, innerRect.height >= 2 else { return }

    // Run squarified layout on children within innerRect.
    let childRects = squarify(
        items: children.map { Double($0.size) },
        rect: innerRect
    )

    for (i, childRect) in childRects.enumerated() where i < children.count {
        layoutNode(
            tree: tree,
            nodeIndex: children[i].index,
            sizeMode: sizeMode,
            rect: childRect,
            depth: depth + 1,
            maxDepth: maxDepth,
            totalParentSize: nodeSize,
            segments: &segments
        )
    }
}

// MARK: - Squarified Algorithm

/// Implements the squarified treemap algorithm. Given a list of item sizes
/// (sorted descending) and a bounding rectangle, produces rectangles with
/// near-square aspect ratios.
///
/// - Parameters:
///   - items: Array of sizes (must be positive). Expected sorted descending.
///   - rect: The bounding rectangle to fill.
/// - Returns: Array of CGRects, one per item.
private func squarify(items: [Double], rect: CGRect) -> [CGRect] {
    guard !items.isEmpty else { return [] }

    let totalArea = items.reduce(0, +)
    guard totalArea > 0 else {
        return Array(repeating: .zero, count: items.count)
    }

    let rectArea = Double(rect.width * rect.height)
    let scale = rectArea / totalArea

    // Normalize items to fill the rectangle area.
    let scaled = items.map { $0 * scale }

    var rects = Array(repeating: CGRect.zero, count: items.count)
    var remaining = CGRect(
        x: Double(rect.minX),
        y: Double(rect.minY),
        width: Double(rect.width),
        height: Double(rect.height)
    )
    var index = 0

    while index < scaled.count {
        let shortSide = min(remaining.width, remaining.height)
        guard shortSide > 0 else { break }

        // Determine how many items to place in the current row.
        var row: [Int] = [index]
        var rowSum = scaled[index]
        var bestWorstRatio = worstAspectRatio(row: [scaled[index]], shortSide: shortSide)

        var next = index + 1
        while next < scaled.count {
            let candidate = scaled[next]
            let newSum = rowSum + candidate
            let newRow = row.map { scaled[$0] } + [candidate]
            let newWorst = worstAspectRatio(row: newRow, shortSide: shortSide)

            if newWorst <= bestWorstRatio {
                row.append(next)
                rowSum = newSum
                bestWorstRatio = newWorst
                next += 1
            } else {
                break
            }
        }

        // Lay out the row.
        let rowLength = rowSum / Double(shortSide)
        let isHorizontal = remaining.width >= remaining.height

        var offset: Double = 0
        for rowIndex in row {
            let itemSize = scaled[rowIndex]
            let itemLength = rowSum > 0 ? itemSize / rowLength : 0

            if isHorizontal {
                rects[rowIndex] = CGRect(
                    x: remaining.minX,
                    y: remaining.minY + offset,
                    width: rowLength,
                    height: itemLength
                )
            } else {
                rects[rowIndex] = CGRect(
                    x: remaining.minX + offset,
                    y: remaining.minY,
                    width: itemLength,
                    height: rowLength
                )
            }

            offset += itemLength
        }

        // Shrink the remaining rectangle.
        if isHorizontal {
            remaining = CGRect(
                x: remaining.minX + rowLength,
                y: remaining.minY,
                width: max(0, remaining.width - rowLength),
                height: remaining.height
            )
        } else {
            remaining = CGRect(
                x: remaining.minX,
                y: remaining.minY + rowLength,
                width: remaining.width,
                height: max(0, remaining.height - rowLength)
            )
        }

        index = next
    }

    return rects
}

/// Computes the worst (largest) aspect ratio among items in a row.
/// Lower is better; 1.0 is a perfect square.
private func worstAspectRatio(row: [Double], shortSide: Double) -> Double {
    guard !row.isEmpty, shortSide > 0 else { return .infinity }
    let sum = row.reduce(0, +)
    guard sum > 0 else { return .infinity }

    let s2 = shortSide * shortSide
    var worst: Double = 0

    for item in row {
        guard item > 0 else { continue }
        let ratio1 = (s2 * item) / (sum * sum)
        let ratio2 = (sum * sum) / (s2 * item)
        let ratio = max(ratio1, ratio2)
        worst = max(worst, ratio)
    }

    return worst
}

// MARK: - TreemapView

/// A Canvas-based squarified treemap visualization for disk space analysis.
///
/// The treemap displays the directory hierarchy as nested rectangles. Each rectangle's
/// area is proportional to its file/directory size. Directories are rendered with nested
/// children up to a configurable depth. Labels are shown when rectangles are large enough.
///
/// Supports drill-down navigation, hover highlighting, tooltips, and animated transitions.
struct TreemapView: View {
    /// The file tree data source.
    let tree: FileTree

    /// Observable navigation and interaction state.
    @Bindable var state: VisualizationState

    /// Cached layout segments, recomputed when root, size mode, or container size changes.
    @State private var segments: [RectSegment] = []

    /// Current mouse position in canvas coordinates.
    @State private var mouseLocation: CGPoint? = nil

    /// Tooltip data for the currently hovered segment.
    @State private var tooltip: TooltipData? = nil

    /// The most recent canvas size for debounced layout.
    @State private var currentSize: CGSize = .zero

    /// Resize debounce task handle.
    @State private var resizeTask: Task<Void, Never>? = nil

    /// Animation scale for drill-down.
    @State private var animationScale: Double = 1.0

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                canvas(in: geometry.size)
                    .onAppear {
                        currentSize = geometry.size
                        rebuildLayout(in: geometry.size)
                    }
                    .onChange(of: state.currentRootIndex) { _, _ in
                        animateDrillDown(in: currentSize)
                    }
                    .onChange(of: state.sizeMode) { _, _ in
                        rebuildLayout(in: currentSize)
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        debouncedResize(to: newSize)
                    }

                // Tooltip overlay
                if let tooltip {
                    tooltipView(tooltip, canvasSize: geometry.size)
                }
            }
        }
    }

    // MARK: - Canvas Rendering

    /// The primary Canvas view that draws all treemap rectangles.
    @ViewBuilder
    private func canvas(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            // Draw segments from lowest depth (background) to highest (foreground).
            let sortedSegments = segments.sorted { $0.depth < $1.depth }

            for segment in sortedSegments {
                drawRectSegment(context: &context, segment: segment, canvasSize: canvasSize)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mouseLocation = location
                updateHover(at: location)
            case .ended:
                mouseLocation = nil
                state.hoveredSegmentId = nil
                tooltip = nil
            }
        }
        .onTapGesture {
            handleTap()
        }
        .accessibilityLabel("Treemap disk visualization")
    }

    /// Draws a single rectangle segment with fill, border, and optional labels.
    private func drawRectSegment(
        context: inout GraphicsContext,
        segment: RectSegment,
        canvasSize: CGSize
    ) {
        let rect = segment.rect
        guard rect.width >= 1, rect.height >= 1 else { return }

        let isHovered = state.hoveredSegmentId == segment.id
        let isSelected = state.selectedSegmentId == segment.id

        // Fill color.
        let baseColor = SpacieColors.shade(for: segment.fileType, depth: segment.depth)
        var fillColor = baseColor
        if isHovered {
            fillColor = baseColor.opacity(0.85)
        }
        if isSelected {
            fillColor = baseColor.opacity(0.7)
        }

        let roundedRect = RoundedRectangle(cornerRadius: 2)
            .path(in: rect)

        context.fill(roundedRect, with: .color(fillColor))

        // Border.
        let borderColor = colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color.white.opacity(0.7)
        context.stroke(
            roundedRect,
            with: .color(borderColor),
            lineWidth: VisualizationConstants.treemapBorderWidth
        )

        // Highlight border for hovered/selected.
        if isHovered || isSelected {
            let highlightColor = Color.accentColor.opacity(isSelected ? 0.9 : 0.6)
            context.stroke(roundedRect, with: .color(highlightColor), lineWidth: 2)
        }

        // Text label (name + size) if the rectangle is large enough.
        if segment.canDisplayLabel {
            drawLabel(
                context: &context,
                segment: segment,
                in: rect
            )
        }
    }

    /// Draws the text label (name and optionally size) inside a rectangle segment.
    private func drawLabel(
        context: inout GraphicsContext,
        segment: RectSegment,
        in rect: CGRect
    ) {
        let padding: CGFloat = 4
        let labelRect = rect.insetBy(dx: padding, dy: padding)
        guard labelRect.width > 10, labelRect.height > 10 else { return }

        // Determine text color based on background brightness.
        let textColor: Color = segment.depth <= 1
            ? .white
            : (colorScheme == .dark ? .white : .black)

        // Name label.
        let nameText = Text(segment.name)
            .font(.system(size: nameFont(for: rect)))
            .foregroundColor(textColor.opacity(0.9))

        let resolvedName = context.resolve(nameText)
        let nameSize = resolvedName.measure(in: labelRect.size)

        context.draw(resolvedName, in: CGRect(
            x: labelRect.minX,
            y: labelRect.minY,
            width: min(nameSize.width, labelRect.width),
            height: min(nameSize.height, labelRect.height)
        ))

        // Size sublabel.
        if segment.canDisplaySizeLabel {
            let sizeText = Text(segment.size.formattedSizeShort)
                .font(.system(size: max(9, nameFont(for: rect) - 2)))
                .foregroundColor(textColor.opacity(0.6))

            let resolvedSize = context.resolve(sizeText)
            let sizeTextSize = resolvedSize.measure(in: labelRect.size)
            let sizeY = labelRect.minY + nameSize.height + 1

            if sizeY + sizeTextSize.height <= labelRect.maxY {
                context.draw(resolvedSize, in: CGRect(
                    x: labelRect.minX,
                    y: sizeY,
                    width: min(sizeTextSize.width, labelRect.width),
                    height: min(sizeTextSize.height, labelRect.maxY - sizeY)
                ))
            }
        }
    }

    /// Computes an appropriate font size based on rectangle dimensions.
    private func nameFont(for rect: CGRect) -> CGFloat {
        let minDimension = min(rect.width, rect.height)
        if minDimension > 120 {
            return 12
        } else if minDimension > 60 {
            return 11
        } else {
            return 10
        }
    }

    // MARK: - Tooltip

    /// Tooltip overlay positioned near the mouse cursor.
    @ViewBuilder
    private func tooltipView(_ data: TooltipData, canvasSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(SpacieColors.color(for: data.fileType))
                    .frame(width: 10, height: 10)
                Text(data.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            Text(data.formattedSize)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if data.isDirectory && data.childrenCount > 0 {
                Text("\(data.childrenCount) items")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        .position(
            x: min(max(data.position.x + 16, 80), canvasSize.width - 80),
            y: max(data.position.y - 40, 40)
        )
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    // MARK: - Hit Testing

    /// Determines which segment is under the given point and updates hover state.
    private func updateHover(at point: CGPoint) {
        // Find the deepest (topmost) segment containing the point.
        let hit = segments
            .filter { $0.rect.contains(point) }
            .max { $0.depth < $1.depth }

        guard let hitSegment = hit else {
            state.hoveredSegmentId = nil
            tooltip = nil
            return
        }

        state.hoveredSegmentId = hitSegment.id

        tooltip = TooltipData(
            name: hitSegment.name,
            formattedSize: hitSegment.size.formattedSize,
            fileType: hitSegment.fileType,
            isDirectory: hitSegment.isDirectory,
            childrenCount: hitSegment.childrenCount,
            position: point
        )
    }

    /// Handles a tap/click on the currently hovered segment.
    private func handleTap() {
        guard let hoveredId = state.hoveredSegmentId else { return }

        if let segment = segments.first(where: { $0.id == hoveredId }) {
            if segment.isDirectory && segment.childrenCount > 0 {
                state.drillDown(to: segment.id)
            } else {
                state.selectedSegmentId = segment.id
            }
        }
    }

    // MARK: - Layout

    /// Rebuilds the treemap layout for the given canvas size.
    private func rebuildLayout(in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            segments = []
            return
        }
        segments = buildTreemapLayout(
            tree: tree,
            rootIndex: state.currentRootIndex,
            sizeMode: state.sizeMode,
            rect: CGRect(origin: .zero, size: size),
            maxDepth: VisualizationConstants.treemapMaxDepth
        )
    }

    /// Debounces resize events to avoid excessive layout recalculations.
    private func debouncedResize(to newSize: CGSize) {
        resizeTask?.cancel()
        resizeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(
                Int(VisualizationConstants.resizeDebounceInterval * 1000)
            ))
            guard !Task.isCancelled else { return }
            currentSize = newSize
            rebuildLayout(in: newSize)
        }
    }

    /// Triggers an animated drill-down transition.
    private func animateDrillDown(in size: CGSize) {
        animationScale = 0.95
        rebuildLayout(in: size)
        withAnimation(.spring(duration: VisualizationConstants.drillDownAnimationDuration)) {
            animationScale = 1.0
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Treemap (placeholder)") {
    Text("TreemapView requires a FileTree instance")
        .frame(width: 800, height: 600)
        .background(.background)
}
#endif
