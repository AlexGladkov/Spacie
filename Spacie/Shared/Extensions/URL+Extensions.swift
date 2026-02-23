import Foundation
import AppKit

extension URL {
    /// Returns the file extension (lowercased, without dot).
    var fileExtension: String {
        pathExtension.lowercased()
    }

    /// Returns the file type based on extension.
    var fileType: FileType {
        FileType.from(extension: fileExtension)
    }

    /// Returns the SF Symbol name appropriate for this file/directory.
    var systemImage: String {
        if hasDirectoryPath {
            return "folder.fill"
        }
        switch fileType {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .document: return "doc.text"
        case .archive: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .application: return "app.badge"
        case .system: return "gearshape"
        case .other: return "doc"
        }
    }

    /// Reveals this file in Finder.
    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([self])
    }

    /// Opens Terminal.app at this directory.
    func openInTerminal() {
        let path = hasDirectoryPath ? self.path : deletingLastPathComponent().path
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(path.shellEscaped)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    /// Copies the full path to clipboard.
    func copyPathToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    /// Copies just the file name to clipboard.
    func copyNameToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastPathComponent, forType: .string)
    }
}

extension String {
    /// Escapes a string for safe use in shell commands.
    var shellEscaped: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
