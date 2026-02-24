import Foundation

// MARK: - FileNode Flags

struct FileNodeFlags: OptionSet, Sendable {
    let rawValue: UInt16

    static let isDirectory    = FileNodeFlags(rawValue: 1 << 0)
    static let isSymlink      = FileNodeFlags(rawValue: 1 << 1)
    static let isHidden       = FileNodeFlags(rawValue: 1 << 2)
    static let isRestricted   = FileNodeFlags(rawValue: 1 << 3)
    static let isPackage      = FileNodeFlags(rawValue: 1 << 4) // .app, .framework
    static let isCompressed   = FileNodeFlags(rawValue: 1 << 5) // APFS transparent compression (decmpfs)
    static let isHardLink     = FileNodeFlags(rawValue: 1 << 6)
    static let isSIPProtected = FileNodeFlags(rawValue: 1 << 7)
    static let isExcluded     = FileNodeFlags(rawValue: 1 << 8)
    static let isVirtual      = FileNodeFlags(rawValue: 1 << 9)
    static let isDeepScanned  = FileNodeFlags(rawValue: 1 << 10)
}

// MARK: - FileType

enum FileType: UInt8, Sendable, CaseIterable, Identifiable {
    case video = 0
    case audio = 1
    case image = 2
    case document = 3
    case archive = 4
    case code = 5
    case application = 6
    case system = 7
    case other = 8

    var id: UInt8 { rawValue }

    var displayName: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Images"
        case .document: "Documents"
        case .archive: "Archives"
        case .code: "Code"
        case .application: "Applications"
        case .system: "System"
        case .other: "Other"
        }
    }

    var localizedName: LocalizedStringResource {
        switch self {
        case .video: "file.type.video"
        case .audio: "file.type.audio"
        case .image: "file.type.image"
        case .document: "file.type.document"
        case .archive: "file.type.archive"
        case .code: "file.type.code"
        case .application: "file.type.application"
        case .system: "file.type.system"
        case .other: "file.type.other"
        }
    }

    static func from(extension ext: String) -> FileType {
        switch ext.lowercased() {
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts":
            return .video
        case "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "opus":
            return .audio
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg", "heic", "heif", "raw", "cr2", "nef", "ico", "psd":
            return .image
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "pages", "numbers", "keynote", "odt", "ods", "csv":
            return .document
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "pkg", "deb", "rpm":
            return .archive
        case "swift", "m", "h", "c", "cpp", "py", "js", "ts", "java", "kt", "rs", "go", "rb",
             "html", "css", "json", "xml", "yaml", "yml", "toml", "sh", "zsh", "bash",
             "sql", "r", "lua", "dart", "scala", "php", "pl", "ex", "exs", "hs",
             "xcodeproj", "xcworkspace", "pbxproj", "storyboard", "xib", "nib":
            return .code
        case "app", "framework", "dylib", "so", "bundle", "plugin", "kext", "prefpane":
            return .application
        case "plist", "log", "crash", "ips", "db", "sqlite", "realm":
            return .system
        default:
            return .other
        }
    }
}

// MARK: - FileNode (Arena-based, compact)

/// Compact file node for arena-based storage.
/// Target: ~48 bytes per node → 5M nodes ≈ 240MB.
struct FileNode: Sendable {
    /// Offset into the string pool for this node's name.
    var nameOffset: UInt32
    /// Length of the name in the string pool.
    var nameLength: UInt16
    /// Index of the parent node in the flat array (UInt32.max = root).
    var parentIndex: UInt32
    /// Index of the first child (0 = no children).
    var firstChildIndex: UInt32
    /// Index of the next sibling (0 = no next sibling).
    var nextSiblingIndex: UInt32
    /// Logical file size (as reported by stat.st_size).
    var logicalSize: UInt64
    /// Physical size on disk (stat.st_blocks * 512).
    var physicalSize: UInt64
    /// Bitfield flags (directory, symlink, hidden, etc.).
    var flags: FileNodeFlags
    /// File type classification.
    var fileType: FileType
    /// Modification time (unix timestamp, seconds since epoch).
    var modTime: UInt32
    /// Number of direct children.
    var childCount: UInt32
    /// Number of direct entries from `readdir()` during shallow scan.
    /// Used as a size proxy in Phase 1 (Yellow) visualization.
    var entryCount: UInt32 = 0
    /// inode number (for hard link deduplication).
    var inode: UInt64
    /// Directory modification time (`st_mtimespec.tv_sec`) as UInt64.
    /// Only meaningful for directory nodes; 0 for files.
    /// Used by incremental cache validation to detect structural changes.
    var dirMtime: UInt64 = 0

    var isDirectory: Bool { flags.contains(.isDirectory) }
    var isSymlink: Bool { flags.contains(.isSymlink) }
    var isHidden: Bool { flags.contains(.isHidden) }
    var isRestricted: Bool { flags.contains(.isRestricted) }
    var isPackage: Bool { flags.contains(.isPackage) }
    var isCompressed: Bool { flags.contains(.isCompressed) }
    var isHardLink: Bool { flags.contains(.isHardLink) }
    var isSIPProtected: Bool { flags.contains(.isSIPProtected) }
    var isExcluded: Bool { flags.contains(.isExcluded) }
    var isVirtual: Bool { flags.contains(.isVirtual) }
    var isDeepScanned: Bool { flags.contains(.isDeepScanned) }

    var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modTime))
    }
}

// MARK: - RawFileNode (from scanner, before tree insertion)

struct RawFileNode: Sendable {
    let name: String
    let path: String
    let logicalSize: UInt64
    let physicalSize: UInt64
    let flags: FileNodeFlags
    let fileType: FileType
    let modTime: UInt32
    let inode: UInt64
    let depth: Int
    let parentPath: String
    var entryCount: UInt32 = 0
    /// Directory modification time (`st_mtimespec.tv_sec`) as UInt64.
    /// Only meaningful for directory nodes; 0 for files.
    var dirMtime: UInt64 = 0
}

// MARK: - FileNodeInfo (rich info for UI display)

struct FileNodeInfo: Identifiable, Sendable {
    let id: UInt32 // index in tree
    let name: String
    let fullPath: String
    let logicalSize: UInt64
    let physicalSize: UInt64
    let isDirectory: Bool
    let fileType: FileType
    let modificationDate: Date
    let childCount: UInt32
    var entryCount: UInt32 = 0
    let depth: Int
    let flags: FileNodeFlags
    /// Directory modification time (`st_mtimespec.tv_sec`) as UInt64.
    /// Only meaningful for directory nodes; 0 for files.
    var dirMtime: UInt64 = 0

    var isVirtual: Bool { flags.contains(.isVirtual) }
}
