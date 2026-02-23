import SwiftUI

// MARK: - Conditional Modifier

extension View {
    /// Applies a modifier only when the condition is true.
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies a modifier only when the optional value is non-nil.
    @ViewBuilder
    func ifLet<T, Transform: View>(_ value: T?, transform: (Self, T) -> Transform) -> some View {
        if let value {
            transform(self, value)
        } else {
            self
        }
    }
}

// MARK: - Quick Look

#if canImport(QuickLookUI)
import QuickLookUI

struct QuickLookPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.previewItem = url as QLPreviewItem
        return view ?? QLPreviewView()
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as QLPreviewItem
    }
}
#endif

// MARK: - Tooltip on Hover

struct TooltipModifier: ViewModifier {
    let text: String
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
            }
            .help(text)
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        modifier(TooltipModifier(text: text))
    }
}

// MARK: - Keyboard Shortcut Helpers

extension KeyboardShortcut {
    static let rescan = KeyboardShortcut("r", modifiers: .command)
    static let sunburst = KeyboardShortcut("1", modifiers: .command)
    static let treemap = KeyboardShortcut("2", modifiers: .command)
    static let goBack = KeyboardShortcut("[", modifiers: .command)
    static let goForward = KeyboardShortcut("]", modifiers: .command)
    static let goParent = KeyboardShortcut(.upArrow, modifiers: .command)
    static let goToFolder = KeyboardShortcut("g", modifiers: [.command, .shift])
    static let moveToDropZone = KeyboardShortcut(.delete, modifiers: .command)
    static let emptyDropZone = KeyboardShortcut(.delete, modifiers: [.command, .shift])
    static let search = KeyboardShortcut("f", modifiers: .command)
    static let getInfo = KeyboardShortcut("i", modifiers: .command)
}

// MARK: - File Size Badge

struct FileSizeBadge: View {
    let size: UInt64
    let threshold: UInt64

    var body: some View {
        Text(size.formattedSize)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        if size > threshold * 10 {
            return .red
        } else if size > threshold {
            return .orange
        } else {
            return .secondary
        }
    }
}

// MARK: - Usage Bar

struct UsageBar: View {
    let used: UInt64
    let total: UInt64
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(SpacieColors.progressTrack)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(barColor)
                    .frame(width: max(0, geo.size.width * percentage))
            }
        }
        .frame(height: height)
    }

    private var percentage: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(used) / CGFloat(total)
    }

    private var barColor: Color {
        let pct = percentage
        if pct > 0.9 { return .red }
        if pct > 0.75 { return .orange }
        return .accentColor
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title2)
                .fontWeight(.medium)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
