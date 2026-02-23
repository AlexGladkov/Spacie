import SwiftUI

// MARK: - BreadcrumbView

/// A horizontal navigation breadcrumb bar displayed above the visualization.
///
/// Shows the path from the scan root to the current drill-down directory as
/// clickable segments separated by chevron icons. Clicking any ancestor segment
/// navigates to that level. The current (last) segment is styled as primary/bold;
/// previous segments use secondary color and are clickable.
///
/// If the breadcrumb trail exceeds available space, leading segments are collapsed
/// into a "..." truncation indicator.
struct BreadcrumbView: View {
    /// The file tree data source for resolving breadcrumb names.
    let tree: FileTree

    /// Observable navigation state shared with the visualization.
    @Bindable var state: VisualizationState

    /// Maximum number of visible breadcrumb segments before truncation.
    private let maxVisibleSegments: Int = 6

    var body: some View {
        let items = state.breadcrumb(from: tree)

        HStack(spacing: 0) {
            // Back / Forward buttons
            navigationButtons

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 6)

            // Breadcrumb trail
            breadcrumbTrail(items: items)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: - Navigation Buttons

    /// Back and forward navigation buttons styled as native macOS controls.
    @ViewBuilder
    private var navigationButtons: some View {
        HStack(spacing: 2) {
            Button {
                state.navigateBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!state.canNavigateBack)
            .help("Navigate Back")
            .keyboardShortcut("[", modifiers: .command)

            Button {
                state.navigateForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!state.canNavigateForward)
            .help("Navigate Forward")
            .keyboardShortcut("]", modifiers: .command)
        }
    }

    // MARK: - Breadcrumb Trail

    /// The horizontal trail of breadcrumb segments with separators.
    @ViewBuilder
    private func breadcrumbTrail(items: [BreadcrumbItem]) -> some View {
        let displayItems = truncatedItems(from: items)

        ForEach(Array(displayItems.enumerated()), id: \.offset) { offset, item in
            if offset > 0 {
                separator
            }

            if item.index == UInt32.max {
                // Truncation indicator
                truncationIndicator(fullItems: items)
            } else {
                breadcrumbSegment(item: item, isLast: offset == displayItems.count - 1)
            }
        }
    }

    /// A single clickable breadcrumb segment.
    @ViewBuilder
    private func breadcrumbSegment(item: BreadcrumbItem, isLast: Bool) -> some View {
        if isLast {
            // Current directory: bold, primary color, not clickable.
            Text(item.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        } else {
            // Ancestor: secondary color, clickable.
            Button {
                state.navigateToBreadcrumb(at: item.index)
            } label: {
                Text(item.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    /// The chevron separator between breadcrumb segments.
    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(SpacieColors.breadcrumbSeparator)
            .padding(.horizontal, 4)
    }

    /// The "..." truncation indicator that expands into a menu on click.
    @ViewBuilder
    private func truncationIndicator(fullItems: [BreadcrumbItem]) -> some View {
        Menu {
            // Show all collapsed items as menu entries.
            let collapsed = collapsedItems(from: fullItems)
            ForEach(collapsed) { item in
                Button(item.name) {
                    state.navigateToBreadcrumb(at: item.index)
                }
            }
        } label: {
            Text("...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Truncation Logic

    /// Produces the display items, replacing middle segments with a truncation
    /// indicator if there are too many.
    private func truncatedItems(from items: [BreadcrumbItem]) -> [BreadcrumbItem] {
        guard items.count > maxVisibleSegments else { return items }

        // Show: first item, "...", last (maxVisibleSegments - 2) items.
        let tailCount = maxVisibleSegments - 2
        let truncationMarker = BreadcrumbItem(index: UInt32.max, name: "...")

        var result: [BreadcrumbItem] = [items[0], truncationMarker]
        result.append(contentsOf: items.suffix(tailCount))
        return result
    }

    /// Returns the items that were collapsed into the "..." indicator.
    private func collapsedItems(from items: [BreadcrumbItem]) -> [BreadcrumbItem] {
        guard items.count > maxVisibleSegments else { return [] }
        let tailCount = maxVisibleSegments - 2
        let startIndex = 1
        let endIndex = items.count - tailCount
        guard endIndex > startIndex else { return [] }
        return Array(items[startIndex..<endIndex])
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Breadcrumb (placeholder)") {
    VStack {
        Text("BreadcrumbView requires a FileTree instance")
    }
    .frame(width: 600, height: 40)
    .background(.bar)
}
#endif
