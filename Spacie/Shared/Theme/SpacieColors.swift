import SwiftUI

// MARK: - SpacieColors

enum SpacieColors {
    // MARK: File Type Colors

    static func color(for fileType: FileType) -> Color {
        switch fileType {
        case .video:       Color(red: 0.29, green: 0.56, blue: 0.85) // #4A90D9
        case .audio:       Color(red: 0.61, green: 0.35, blue: 0.71) // #9B59B6
        case .image:       Color(red: 0.15, green: 0.68, blue: 0.38) // #27AE60
        case .document:    Color(red: 0.90, green: 0.49, blue: 0.13) // #E67E22
        case .archive:     Color(red: 0.91, green: 0.30, blue: 0.24) // #E74C3C
        case .code:        Color(red: 0.95, green: 0.77, blue: 0.06) // #F1C40F
        case .application: Color(red: 0.10, green: 0.74, blue: 0.61) // #1ABC9C
        case .system:      Color(red: 0.58, green: 0.65, blue: 0.65) // #95A5A6
        case .other:       Color(red: 0.74, green: 0.76, blue: 0.78) // #BDC3C7
        }
    }

    /// Returns a lighter/darker shade for nested items.
    /// `depth` controls the shade level (0 = base, positive = lighter).
    static func shade(for fileType: FileType, depth: Int) -> Color {
        let base = color(for: fileType)
        let adjustment = Double(depth) * 0.08
        return base.opacity(max(0.3, 1.0 - adjustment))
    }

    // MARK: UI Colors

    static let dropZoneBackground = Color.red.opacity(0.08)
    static let dropZoneBorder = Color.red.opacity(0.4)
    static let dropZoneActive = Color.red.opacity(0.15)

    static let restrictedBackground = Color.gray.opacity(0.15)
    static let restrictedForeground = Color.secondary

    static let warningBackground = Color.orange.opacity(0.1)
    static let warningForeground = Color.orange

    static let progressTrack = Color.gray.opacity(0.2)
    static let progressFill = Color.accentColor

    static let breadcrumbSeparator = Color.secondary.opacity(0.5)
    static let hoverHighlight = Color.accentColor.opacity(0.2)

    // MARK: System Category Colors

    static let freeSpace = Color.gray.opacity(0.2)
    static let purgeableSpace = Color.blue.opacity(0.3)
    static let systemData = Color.gray.opacity(0.5)
    static let userData = Color.blue
    static let applicationsColor = Color.green
}

// MARK: - Size Formatting

extension UInt64 {
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }

    var formattedSizeShort: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: Int64(self))
    }
}

extension Int64 {
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

// MARK: - Number Formatting

extension UInt64 {
    var formattedCount: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: self)) ?? "\(self)"
    }
}

// MARK: - Time Formatting

extension TimeInterval {
    var formattedDuration: String {
        if self < 1 {
            return String(format: "%.0fms", self * 1000)
        } else if self < 60 {
            return String(format: "%.1fs", self)
        } else {
            let minutes = Int(self) / 60
            let seconds = Int(self) % 60
            return "\(minutes)m \(seconds)s"
        }
    }
}
