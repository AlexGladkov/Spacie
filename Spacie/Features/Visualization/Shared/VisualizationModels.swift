import Foundation
import SwiftUI

// MARK: - SegmentData (Sunburst)

/// Represents a single arc segment in the sunburst visualization.
/// Each segment corresponds to a node in the file tree, positioned
/// by its angular range within a concentric ring at a given depth.
struct SegmentData: Identifiable, Sendable {
    /// Unique identifier matching the tree index of the file node.
    let id: UInt32
    /// Display name of the file or directory.
    let name: String
    /// Size in bytes (logical or physical depending on mode).
    let size: UInt64
    /// Classified file type used for color mapping.
    let fileType: FileType
    /// Depth level relative to the current visualization root (0 = center).
    let depth: Int
    /// Tree index of the parent node (UInt32.max for the root segment).
    let parentId: UInt32
    /// Start angle in radians for this arc segment.
    let startAngle: Double
    /// End angle in radians for this arc segment.
    let endAngle: Double
    /// Number of direct children this node has in the tree.
    let childrenCount: UInt32
    /// Whether this node represents a directory.
    let isDirectory: Bool
    /// Whether this node is a virtual "Other" node from Smart Scan.
    let isVirtual: Bool

    /// The angular sweep of this segment in radians.
    var sweepAngle: Double {
        endAngle - startAngle
    }

    /// The angular sweep in degrees.
    var sweepDegrees: Double {
        sweepAngle * 180.0 / .pi
    }

    /// The midpoint angle in radians, useful for label placement.
    var midAngle: Double {
        (startAngle + endAngle) / 2.0
    }
}

// MARK: - RectSegment (Treemap)

/// Represents a single rectangle in the treemap visualization.
/// Each rectangle corresponds to a node in the file tree, positioned
/// within its parent rectangle proportional to its size.
struct RectSegment: Identifiable, Sendable {
    /// Unique identifier matching the tree index of the file node.
    let id: UInt32
    /// Display name of the file or directory.
    let name: String
    /// Size in bytes (logical or physical depending on mode).
    let size: UInt64
    /// Classified file type used for color mapping.
    let fileType: FileType
    /// Depth level relative to the current visualization root (0 = outermost).
    let depth: Int
    /// Bounding rectangle for this segment in the treemap canvas.
    let rect: CGRect
    /// Number of direct children this node has in the tree.
    let childrenCount: UInt32
    /// Whether this node represents a directory.
    let isDirectory: Bool
    /// Whether this node is a virtual "Other" node from Smart Scan.
    let isVirtual: Bool

    /// Whether the rectangle is large enough to display a text label.
    /// Minimum 60pt wide and 30pt tall.
    var canDisplayLabel: Bool {
        rect.width >= 60 && rect.height >= 30
    }

    /// Whether the rectangle is large enough to display a size sublabel.
    var canDisplaySizeLabel: Bool {
        rect.width >= 60 && rect.height >= 46
    }
}

// MARK: - BreadcrumbItem

/// A single item in the navigation breadcrumb trail.
struct BreadcrumbItem: Identifiable, Sendable {
    /// Tree index of the node this breadcrumb represents.
    let index: UInt32
    /// Display name of the directory.
    let name: String

    var id: UInt32 { index }
}

// MARK: - VisualizationState

/// Observable state object that drives navigation and interaction
/// for both sunburst and treemap visualizations. Tracks the current
/// root for drill-down, hover/selection state, and a history stack
/// for back/forward navigation.
@MainActor
@Observable
final class VisualizationState {
    // MARK: Navigation

    /// The tree index of the node currently displayed as root.
    var currentRootIndex: UInt32

    /// Stack of previously visited root indices for back navigation.
    /// The last element is the most recent previous root.
    private(set) var backHistory: [UInt32] = []

    /// Stack of root indices for forward navigation (populated when going back).
    private(set) var forwardHistory: [UInt32] = []

    /// The tree index of the absolute root (top-level scanned directory).
    let absoluteRootIndex: UInt32

    // MARK: Interaction

    /// Tree index of the segment currently under the mouse cursor, if any.
    var hoveredSegmentId: UInt32?

    /// Tree index of the currently selected segment, if any.
    var selectedSegmentId: UInt32?

    /// The size display mode (logical vs physical).
    var sizeMode: SizeMode

    /// Whether to use entry count instead of file sizes for layout proportions.
    /// Set to `true` during Yellow phase (approximate visualization).
    var useEntryCount: Bool = false

    // MARK: Initialization

    /// Creates a new visualization state rooted at the given tree index.
    /// - Parameters:
    ///   - rootIndex: The tree index of the root node.
    ///   - sizeMode: The initial size display mode. Defaults to `.logical`.
    init(rootIndex: UInt32, sizeMode: SizeMode = .logical) {
        self.currentRootIndex = rootIndex
        self.absoluteRootIndex = rootIndex
        self.sizeMode = sizeMode
    }

    // MARK: Navigation Methods

    /// Whether back navigation is available.
    var canNavigateBack: Bool {
        !backHistory.isEmpty
    }

    /// Whether forward navigation is available.
    var canNavigateForward: Bool {
        !forwardHistory.isEmpty
    }

    /// Whether the current root is the absolute root.
    var isAtRoot: Bool {
        currentRootIndex == absoluteRootIndex
    }

    /// Drill down into a directory, making it the new visualization root.
    /// Pushes the current root onto the back history and clears forward history.
    /// - Parameter index: The tree index of the directory to drill into.
    func drillDown(to index: UInt32) {
        guard index != currentRootIndex else { return }
        backHistory.append(currentRootIndex)
        forwardHistory.removeAll()
        currentRootIndex = index
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }

    /// Navigate back to the previous root in the history stack.
    /// Pushes the current root onto the forward history.
    func navigateBack() {
        guard let previous = backHistory.popLast() else { return }
        forwardHistory.append(currentRootIndex)
        currentRootIndex = previous
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }

    /// Navigate forward to the next root in the forward history.
    /// Pushes the current root onto the back history.
    func navigateForward() {
        guard let next = forwardHistory.popLast() else { return }
        backHistory.append(currentRootIndex)
        currentRootIndex = next
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }

    /// Navigate directly to the absolute root, clearing forward history.
    func navigateToRoot() {
        guard currentRootIndex != absoluteRootIndex else { return }
        backHistory.append(currentRootIndex)
        forwardHistory.removeAll()
        currentRootIndex = absoluteRootIndex
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }

    /// Navigate to a specific ancestor in the breadcrumb trail.
    /// - Parameter index: The tree index of the ancestor to navigate to.
    func navigateToBreadcrumb(at index: UInt32) {
        guard index != currentRootIndex else { return }
        backHistory.append(currentRootIndex)
        forwardHistory.removeAll()
        currentRootIndex = index
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }

    /// Build the breadcrumb trail from the absolute root to the current root.
    /// - Parameter tree: The file tree used to resolve parent relationships and names.
    /// - Returns: An ordered array of breadcrumb items from root to current.
    func breadcrumb(from tree: FileTree) -> [BreadcrumbItem] {
        var items: [BreadcrumbItem] = []
        var index = currentRootIndex

        while true {
            let info = tree.nodeInfo(at: index)
            items.append(BreadcrumbItem(index: index, name: info.name))
            if index == absoluteRootIndex { break }
            let node = tree[index]
            if node.parentIndex == UInt32.max || node.parentIndex == index {
                break
            }
            index = node.parentIndex
        }

        return items.reversed()
    }

    /// Resets all navigation state back to the absolute root.
    func reset() {
        currentRootIndex = absoluteRootIndex
        backHistory.removeAll()
        forwardHistory.removeAll()
        hoveredSegmentId = nil
        selectedSegmentId = nil
    }
}

// MARK: - TooltipData

/// Data model for the hover tooltip displayed over segments.
struct TooltipData: Sendable {
    /// Display name of the hovered item.
    let name: String
    /// Formatted size string.
    let formattedSize: String
    /// File type for color reference.
    let fileType: FileType
    /// Whether the hovered item is a directory.
    let isDirectory: Bool
    /// Number of children if it is a directory.
    let childrenCount: UInt32
    /// Screen position where the tooltip should appear.
    let position: CGPoint
}

// MARK: - Layout Constants

/// Shared constants used across both visualization modes.
enum VisualizationConstants {
    /// Maximum number of concentric rings displayed in sunburst mode.
    static let sunburstMaxRings: Int = 5

    /// Maximum depth levels displayed in treemap mode.
    static let treemapMaxDepth: Int = 3

    /// Minimum percentage of a ring's total angle for a segment to be shown individually.
    /// Segments smaller than this are grouped into "Other".
    static let minimumSegmentPercent: Double = 0.01

    /// Gap between adjacent segments in degrees (sunburst).
    static let segmentGapDegrees: Double = 0.5

    /// Border width between treemap rectangles in points.
    static let treemapBorderWidth: CGFloat = 1.0

    /// Minimum rectangle dimensions for displaying a text label.
    static let treemapMinLabelWidth: CGFloat = 60.0
    static let treemapMinLabelHeight: CGFloat = 30.0

    /// Minimum rectangle dimensions for displaying a size sublabel.
    static let treemapMinSizeLabelHeight: CGFloat = 46.0

    /// Debounce interval for recalculating treemap layout on resize.
    static let resizeDebounceInterval: TimeInterval = 0.1

    /// Animation duration for drill-down transitions.
    static let drillDownAnimationDuration: Double = 0.35
}
