import AppKit

extension NSImage {
    /// Returns the system icon for a file type.
    static func icon(for fileType: FileType) -> NSImage {
        let symbolName: String
        switch fileType {
        case .video:       symbolName = "film"
        case .audio:       symbolName = "music.note"
        case .image:       symbolName = "photo"
        case .document:    symbolName = "doc.text"
        case .archive:     symbolName = "archivebox"
        case .code:        symbolName = "chevron.left.forwardslash.chevron.right"
        case .application: symbolName = "app.badge"
        case .system:      symbolName = "gearshape"
        case .other:       symbolName = "doc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: fileType.displayName)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: "File")!
    }

    /// Returns the system icon for a volume.
    static func volumeIcon(for volumeType: VolumeType) -> NSImage {
        let symbolName: String
        switch volumeType {
        case .internal:    symbolName = "internaldrive"
        case .external:    symbolName = "externaldrive"
        case .network:     symbolName = "externaldrive.connected.to.line.below"
        case .disk_image:  symbolName = "opticaldisc"
        }
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: volumeType.displayName)
            ?? NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "Drive")!
    }
}
