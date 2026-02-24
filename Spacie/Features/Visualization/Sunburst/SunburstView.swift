import SwiftUI

// MARK: - Sunburst Layout Builder

/// Builds a flat array of `SegmentData` representing all visible arc segments
/// in the sunburst visualization for a given root node.
///
/// The algorithm walks the tree breadth-first from `rootIndex`, assigning angular
/// ranges to each child proportional to its size. Children smaller than 1% of their
/// ring's total are grouped into a synthetic "Other" segment.
///
/// - Parameters:
///   - tree: The file tree data source.
///   - rootIndex: The tree index of the current visualization root.
///   - sizeMode: Whether to use logical or physical sizes.
///   - maxRings: Maximum number of concentric rings to generate (default 5).
///   - useEntryCount: When `true`, proportions are based on `entryCount` instead
///     of byte sizes. Used during Yellow phase for approximate visualization.
/// - Returns: An array of `SegmentData` for all visible segments.
func buildSunburstLayout(
    tree: FileTree,
    rootIndex: UInt32,
    sizeMode: SizeMode,
    maxRings: Int = VisualizationConstants.sunburstMaxRings,
    useEntryCount: Bool = false
) -> [SegmentData] {
    var segments: [SegmentData] = []

    // Closure that returns the "size" value for a node, using either entry count
    // (Yellow phase approximate) or actual byte sizes (Green phase accurate).
    let sizeOf: (UInt32) -> UInt64 = useEntryCount
        ? { UInt64(tree.entryCount(of: $0)) }
        : { tree.size(of: $0, mode: sizeMode) }

    let rootSize = sizeOf(rootIndex)
    guard rootSize > 0 else { return segments }

    let rootInfo = tree.nodeInfo(at: rootIndex)

    // Add the center root segment (full circle).
    let rootSegment = SegmentData(
        id: rootIndex,
        name: rootInfo.name,
        size: rootSize,
        fileType: rootInfo.fileType,
        depth: 0,
        parentId: UInt32.max,
        startAngle: 0,
        endAngle: 2 * .pi,
        childrenCount: rootInfo.childCount,
        isDirectory: rootInfo.isDirectory,
        isVirtual: rootInfo.isVirtual
    )
    segments.append(rootSegment)

    // BFS queue: (nodeIndex, depth, parentAngleStart, parentAngleEnd, parentTreeIndex)
    struct QueueEntry {
        let nodeIndex: UInt32
        let depth: Int
        let angleStart: Double
        let angleEnd: Double
        let parentId: UInt32
    }

    var queue: [QueueEntry] = [
        QueueEntry(
            nodeIndex: rootIndex,
            depth: 0,
            angleStart: 0,
            angleEnd: 2 * .pi,
            parentId: UInt32.max
        )
    ]

    let gapRadians = VisualizationConstants.segmentGapDegrees * .pi / 180.0

    while !queue.isEmpty {
        let current = queue.removeFirst()
        let nextDepth = current.depth + 1
        guard nextDepth <= maxRings else { continue }

        let childIndices = tree.sortedChildren(of: current.nodeIndex, by: .size)
        guard !childIndices.isEmpty else { continue }

        let parentSize = sizeOf(current.nodeIndex)
        guard parentSize > 0 else { continue }

        let parentSweep = current.angleEnd - current.angleStart
        let minAngle = parentSweep * VisualizationConstants.minimumSegmentPercent

        var angle = current.angleStart
        var otherSize: UInt64 = 0
        var otherFileType: FileType = .other

        for childIndex in childIndices {
            let childSize = sizeOf(childIndex)
            guard childSize > 0 else { continue }

            let proportion = Double(childSize) / Double(parentSize)
            let sweep = parentSweep * proportion

            if sweep < minAngle {
                otherSize += childSize
                continue
            }

            // Apply gap: reduce the sweep slightly, but never below zero.
            let effectiveSweep = max(0, sweep - gapRadians)
            let segmentStart = angle
            let segmentEnd = angle + effectiveSweep

            let childInfo = tree.nodeInfo(at: childIndex)
            let segment = SegmentData(
                id: childIndex,
                name: childInfo.name,
                size: childSize,
                fileType: childInfo.fileType,
                depth: nextDepth,
                parentId: current.nodeIndex,
                startAngle: segmentStart,
                endAngle: segmentEnd,
                childrenCount: childInfo.childCount,
                isDirectory: childInfo.isDirectory,
                isVirtual: childInfo.isVirtual
            )
            segments.append(segment)

            // Enqueue children if this is a directory.
            if childInfo.isDirectory && childInfo.childCount > 0 {
                queue.append(QueueEntry(
                    nodeIndex: childIndex,
                    depth: nextDepth,
                    angleStart: segmentStart,
                    angleEnd: segmentEnd,
                    parentId: current.nodeIndex
                ))
            }

            angle += sweep
        }

        // Add "Other" segment for grouped small items.
        if otherSize > 0 {
            let proportion = Double(otherSize) / Double(parentSize)
            let sweep = parentSweep * proportion
            let effectiveSweep = max(0, sweep - gapRadians)
            let segmentStart = angle
            let segmentEnd = angle + effectiveSweep

            let otherSegment = SegmentData(
                id: UInt32.max - UInt32(nextDepth),
                name: "Other",
                size: otherSize,
                fileType: otherFileType,
                depth: nextDepth,
                parentId: current.nodeIndex,
                startAngle: segmentStart,
                endAngle: segmentEnd,
                childrenCount: 0,
                isDirectory: false,
                isVirtual: false
            )
            segments.append(otherSegment)
        }
    }

    return segments
}

// MARK: - SunburstView

/// A Canvas-based radial treemap visualization for disk space analysis.
///
/// The sunburst chart displays a directory hierarchy as concentric rings emanating
/// from a center circle. The center represents the current root directory; each
/// successive ring represents one level of subdirectories. Arc angles are proportional
/// to file/directory sizes.
///
/// Supports drill-down navigation, hover highlighting, tooltips, and animated transitions.
struct SunburstView: View {
    /// The file tree data source.
    let tree: FileTree

    /// Observable navigation and interaction state.
    @Bindable var state: VisualizationState

    /// Current mouse location in the canvas coordinate space.
    @State private var mouseLocation: CGPoint? = nil

    /// Cached layout segments, recomputed when root or size mode changes.
    @State private var segments: [SegmentData] = []

    /// Tooltip data for the currently hovered segment.
    @State private var tooltip: TooltipData? = nil

    /// Animation trigger for drill-down transitions.
    @State private var animationPhase: Double = 1.0

    /// The canvas size from the most recent layout pass.
    @State private var canvasSize: CGSize = .zero

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                canvas(in: geometry.size)
                    .onAppear {
                        canvasSize = geometry.size
                        rebuildLayout()
                    }
                    .onChange(of: state.currentRootIndex) { _, _ in
                        animateDrillDown()
                    }
                    .onChange(of: state.sizeMode) { _, _ in
                        rebuildLayout()
                    }
                    .onChange(of: state.useEntryCount) { _, _ in
                        rebuildLayout()
                    }
                    .onChange(of: geometry.size) { _, newSize in
                        canvasSize = newSize
                    }

                // Tooltip overlay
                if let tooltip {
                    tooltipView(tooltip)
                }

                // Center label
                centerLabel(in: geometry.size)
            }
        }
    }

    // MARK: - Canvas Rendering

    /// The primary Canvas view that draws all sunburst arc segments.
    @ViewBuilder
    private func canvas(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let maxRadius = min(canvasSize.width, canvasSize.height) / 2 * 0.92
            let centerRadius = maxRadius * 0.18
            let ringCount = min(
                VisualizationConstants.sunburstMaxRings,
                (segments.map(\.depth).max() ?? 0)
            )
            let ringWidth = ringCount > 0
                ? (maxRadius - centerRadius) / CGFloat(ringCount)
                : maxRadius - centerRadius

            // Draw center circle (root).
            drawCenterCircle(
                context: &context,
                center: center,
                radius: centerRadius
            )

            // Draw ring segments from innermost to outermost.
            for segment in segments where segment.depth > 0 {
                let innerR = centerRadius + CGFloat(segment.depth - 1) * ringWidth
                let outerR = centerRadius + CGFloat(segment.depth) * ringWidth
                let effectiveOuterR = innerR + (outerR - innerR) * CGFloat(animationPhase)

                guard effectiveOuterR > innerR else { continue }

                drawArcSegment(
                    context: &context,
                    center: center,
                    innerRadius: innerR,
                    outerRadius: effectiveOuterR,
                    segment: segment
                )
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                mouseLocation = location
                updateHover(at: location, canvasSize: canvasSize)
            case .ended:
                mouseLocation = nil
                state.hoveredSegmentId = nil
                tooltip = nil
            }
        }
        .onTapGesture {
            handleTap()
        }
        .accessibilityLabel("Sunburst disk visualization")
    }

    /// Draws the center circle representing the current root directory.
    private func drawCenterCircle(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        let circle = Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))

        let isHovered = state.hoveredSegmentId == state.currentRootIndex
        let fillColor: Color = isHovered
            ? SpacieColors.hoverHighlight
            : (colorScheme == .dark
                ? Color.white.opacity(0.06)
                : Color.black.opacity(0.03))

        context.fill(circle, with: .color(fillColor))
        context.stroke(
            circle,
            with: .color(Color.primary.opacity(0.15)),
            lineWidth: 1
        )
    }

    /// Draws a single arc segment (annular sector) for the given segment data.
    private func drawArcSegment(
        context: inout GraphicsContext,
        center: CGPoint,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        segment: SegmentData
    ) {
        let path = arcPath(
            center: center,
            innerRadius: innerRadius,
            outerRadius: outerRadius,
            startAngle: Angle(radians: segment.startAngle - .pi / 2),
            endAngle: Angle(radians: segment.endAngle - .pi / 2)
        )

        if segment.isVirtual {
            // Virtual segments use a muted grey fill with diagonal hatching.
            context.fill(path, with: .color(SpacieColors.smartScanOtherFill))
            drawHatchPattern(context: &context, in: path, rect: path.boundingRect)
        } else {
            let baseColor = SpacieColors.shade(for: segment.fileType, depth: segment.depth)
            let isHovered = state.hoveredSegmentId == segment.id
            let isSelected = state.selectedSegmentId == segment.id

            var fillColor = baseColor
            if isHovered {
                fillColor = baseColor.opacity(0.85)
            }
            if isSelected {
                fillColor = baseColor.opacity(0.7)
            }

            context.fill(path, with: .color(fillColor))

            // Highlight border for hovered/selected segments.
            if isHovered || isSelected {
                let highlightColor = Color.accentColor.opacity(isSelected ? 0.8 : 0.5)
                context.stroke(path, with: .color(highlightColor), lineWidth: 2)
            }
        }

        // Draw segment border.
        let borderColor = colorScheme == .dark
            ? Color.black.opacity(0.4)
            : Color.white.opacity(0.6)
        context.stroke(path, with: .color(borderColor), lineWidth: 0.5)
    }

    /// Draws a diagonal hatch pattern clipped to the given path.
    private func drawHatchPattern(context: inout GraphicsContext, in path: Path, rect: CGRect) {
        let spacing: CGFloat = 6
        let lineWidth: CGFloat = 1
        var inner = context
        inner.clip(to: path)
        let maxDim = max(rect.width, rect.height) * 2
        var offset: CGFloat = -maxDim
        while offset < maxDim {
            let start = CGPoint(x: rect.midX + offset, y: rect.minY)
            let end = CGPoint(x: rect.midX + offset - rect.height, y: rect.maxY)
            var linePath = Path()
            linePath.move(to: start)
            linePath.addLine(to: end)
            inner.stroke(linePath, with: .color(SpacieColors.smartScanOtherHatch), lineWidth: lineWidth)
            offset += spacing
        }
    }

    /// Creates a closed Path for an annular sector (arc segment).
    private func arcPath(
        center: CGPoint,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        startAngle: Angle,
        endAngle: Angle
    ) -> Path {
        var path = Path()

        // Outer arc (clockwise).
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: false
        )

        // Line to inner arc.
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: endAngle,
            endAngle: startAngle,
            clockwise: true
        )

        path.closeSubpath()
        return path
    }

    // MARK: - Center Label

    /// Overlay showing the current directory name and total size at the center.
    @ViewBuilder
    private func centerLabel(in size: CGSize) -> some View {
        let rootInfo = tree.nodeInfo(at: state.currentRootIndex)
        let rootSize = tree.size(of: state.currentRootIndex, mode: state.sizeMode)

        VStack(spacing: 2) {
            Text(rootInfo.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if state.useEntryCount {
                Text("\(rootInfo.entryCount.formatted()) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Text(rootSize.formattedSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: min(size.width, size.height) * 0.15)
        .position(x: size.width / 2, y: size.height / 2)
        .allowsHitTesting(false)
    }

    // MARK: - Tooltip

    /// Tooltip overlay positioned near the mouse cursor.
    @ViewBuilder
    private func tooltipView(_ data: TooltipData) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(SpacieColors.color(for: data.fileType))
                    .frame(width: 8, height: 8)
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

    /// Determines which segment (if any) is under the given point and updates hover state.
    private func updateHover(at point: CGPoint, canvasSize: CGSize) {
        guard let hitSegment = hitTest(at: point, canvasSize: canvasSize) else {
            state.hoveredSegmentId = nil
            tooltip = nil
            return
        }

        state.hoveredSegmentId = hitSegment.id

        if hitSegment.isVirtual {
            let sizeText = state.useEntryCount
                ? "\(hitSegment.size.formatted()) items"
                : hitSegment.size.formattedSize
            tooltip = TooltipData(
                name: "Other \u{2014} \(sizeText) (includes unscanned directories, system data, and snapshots)",
                formattedSize: sizeText,
                fileType: hitSegment.fileType,
                isDirectory: hitSegment.isDirectory,
                childrenCount: hitSegment.childrenCount,
                position: point
            )
        } else {
            tooltip = TooltipData(
                name: hitSegment.name,
                formattedSize: state.useEntryCount
                    ? "\(hitSegment.size.formatted()) items"
                    : hitSegment.size.formattedSize,
                fileType: hitSegment.fileType,
                isDirectory: hitSegment.isDirectory,
                childrenCount: hitSegment.childrenCount,
                position: point
            )
        }
    }

    /// Performs a hit test to find the segment at the given canvas point.
    private func hitTest(at point: CGPoint, canvasSize: CGSize) -> SegmentData? {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let maxRadius = min(canvasSize.width, canvasSize.height) / 2 * 0.92
        let centerRadius = maxRadius * 0.18

        // Check if in center circle.
        if distance <= centerRadius {
            return segments.first { $0.depth == 0 }
        }

        guard distance <= maxRadius else { return nil }

        let ringCount = min(
            VisualizationConstants.sunburstMaxRings,
            (segments.map(\.depth).max() ?? 0)
        )
        guard ringCount > 0 else { return nil }
        let ringWidth = (maxRadius - centerRadius) / CGFloat(ringCount)

        // Determine which ring.
        let ringFloat = (distance - centerRadius) / ringWidth
        let ring = Int(ringFloat) + 1
        guard ring >= 1, ring <= ringCount else { return nil }

        // Compute angle (offset by -pi/2 because drawing starts from top).
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }

        // Find the segment matching this ring and angle.
        return segments.first { segment in
            segment.depth == ring
                && angle >= segment.startAngle
                && angle <= segment.endAngle
        }
    }

    /// Handles a tap/click on the currently hovered segment.
    private func handleTap() {
        guard let hoveredId = state.hoveredSegmentId else { return }

        if let segment = segments.first(where: { $0.id == hoveredId }) {
            // Virtual segments are non-interactive (no drill-down or selection).
            if segment.isVirtual { return }

            if segment.isDirectory && segment.childrenCount > 0 && segment.depth > 0 {
                // Drill down into directory.
                state.drillDown(to: segment.id)
            } else if segment.depth == 0 && state.canNavigateBack {
                // Clicking center navigates back.
                state.navigateBack()
            } else {
                // Select file.
                state.selectedSegmentId = segment.id
            }
        }
    }

    // MARK: - Layout & Animation

    /// Rebuilds the segment layout from the file tree.
    private func rebuildLayout() {
        segments = buildSunburstLayout(
            tree: tree,
            rootIndex: state.currentRootIndex,
            sizeMode: state.sizeMode,
            maxRings: VisualizationConstants.sunburstMaxRings,
            useEntryCount: state.useEntryCount
        )
    }

    /// Triggers an animated drill-down transition.
    private func animateDrillDown() {
        animationPhase = 0.0
        rebuildLayout()
        withAnimation(.spring(duration: VisualizationConstants.drillDownAnimationDuration)) {
            animationPhase = 1.0
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Sunburst (placeholder)") {
    Text("SunburstView requires a FileTree instance")
        .frame(width: 600, height: 600)
        .background(.background)
}
#endif
