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
        // Video
        case "mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "mpg", "mpeg",
             "3gp", "3g2", "mts", "m2ts", "vob", "ogv", "rm", "rmvb", "f4v", "mxf",
             "r3d", "asf", "dv", "divx", "ts":
            return .video
        // Audio
        case "mp3", "wav", "aac", "flac", "ogg", "wma", "m4a", "aiff", "opus",
             "mid", "midi", "ape", "wv", "caf", "dsf", "dff", "ac3", "dts",
             "amr", "au", "ra", "spx", "mka", "pcm", "snd":
            return .audio
        // Images — photos, RAW camera formats, design files
        case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "svg",
             "heic", "heif", "raw", "ico", "psd",
             "avif", "jxl", "jp2", "jfif",
             // Camera RAW
             "cr2", "cr3", "nef", "nrw", "dng", "arw", "orf", "rw2", "raf",
             "pef", "x3f", "3fr", "srw", "rwl", "kdc", "dcr", "mrw", "erf",
             // Design & illustration
             "ai", "eps", "indd", "xcf", "sketch", "afdesign", "afphoto",
             // HDR & specialized
             "exr", "hdr", "tga", "dds", "icns", "cur", "pbm", "pgm", "ppm":
            return .image
        // Documents
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf",
             "pages", "numbers", "keynote", "odt", "ods", "odp", "csv",
             "epub", "mobi", "azw", "azw3", "djvu", "fb2", "cbr", "cbz",
             "md", "tex", "rst", "org", "wps", "wpd",
             "ics", "vcf", "eml", "msg", "mbox":
            return .document
        // Archives
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso", "pkg", "deb", "rpm",
             "tgz", "tbz2", "txz", "zst", "lz", "lzma", "lz4", "sz", "cab", "cpio",
             "jar", "war", "ear", "apk", "ipa", "whl", "egg", "gem", "crx",
             "snap", "flatpak", "nupkg", "vsix":
            return .archive
        // Code & development
        case "swift", "m", "h", "c", "cpp", "cc", "cxx", "hpp", "hxx",
             "py", "pyw", "pyx", "pxd",
             "js", "mjs", "cjs", "jsx", "tsx",
             "java", "kt", "kts", "rs", "go", "rb", "erb",
             "html", "htm", "css", "scss", "sass", "less", "styl",
             "json", "xml", "yaml", "yml", "toml", "ini", "cfg", "conf",
             "sh", "zsh", "bash", "fish", "ps1", "psm1", "bat", "cmd",
             "sql", "r", "lua", "dart", "scala", "php", "pl", "pm",
             "ex", "exs", "hs", "lhs", "ml", "mli", "fs", "fsx", "fsi",
             "clj", "cljs", "cljc", "edn", "elm", "purs",
             "zig", "nim", "v", "cr", "jl", "groovy", "gradle",
             "vue", "svelte", "graphql", "gql", "proto",
             "tf", "hcl", "cmake", "makefile", "mk",
             "dockerfile", "vagrantfile",
             "ipynb", "wasm", "wat", "map",
             "xcodeproj", "xcworkspace", "pbxproj", "storyboard", "xib", "nib",
             "lock", "editorconfig", "gitignore", "gitattributes",
             "env", "properties", "sbt", "cabal", "podspec",
             "gemspec", "csproj", "sln", "vcxproj",
             "o", "a", "d", "hmap", "modulemap", "swiftmodule", "swiftdoc",
             "class", "pyc", "pyo", "elc", "beam":
            return .code
        // Applications & frameworks
        case "app", "framework", "dylib", "so", "dll", "exe", "msi",
             "bundle", "plugin", "kext", "prefpane",
             "xpc", "appex", "qlgenerator", "mdimporter", "saver",
             "action", "workflow", "shortcut",
             "vst", "vst3", "component", "audiounit":
            return .application
        // System & configuration
        case "plist", "log", "crash", "ips",
             "db", "sqlite", "sqlite3", "realm",
             "wal", "shm", "journal",
             "cache", "tmp", "temp", "bak", "old", "orig", "swp",
             "keychain", "provisionprofile", "mobileprovision",
             "cer", "crt", "pem", "key", "p12", "pfx",
             "car", "actool", "storedata", "mom", "momd", "omo",
             "strings", "stringsdict", "lproj",
             "data", "dat", "bin",
             "ttf", "otf", "woff", "woff2", "ttc", "dfont":
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
