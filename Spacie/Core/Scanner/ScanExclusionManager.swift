import Foundation

// MARK: - ScanExclusionRules

/// Immutable set of rules for excluding directories during a file system scan.
///
/// Two kinds of checks are performed:
/// 1. **Basename lookup** — O(1) `Set` membership test against known directory names
///    (e.g. `node_modules`, `.git`, `DerivedData`).
/// 2. **Path prefix match** — linear scan over a small array of absolute path prefixes
///    (e.g. `~/Library/Caches`).
///
/// User-defined exclusions from `~/.spacie/scan-exclusions.txt` are merged into
/// whichever category they match (basename or prefix).
struct ScanExclusionRules: Sendable {

    let excludedBasenames: Set<String>
    let excludedPathPrefixes: [String]

    /// Pre-computed `excludedPathPrefixes[i] + "/"` strings.
    /// Avoids creating a temporary string on every `shouldExclude` call (millions of times).
    private let _prefixesWithSlash: [String]

    init(excludedBasenames: Set<String>, excludedPathPrefixes: [String]) {
        self.excludedBasenames = excludedBasenames
        self.excludedPathPrefixes = excludedPathPrefixes
        self._prefixesWithSlash = excludedPathPrefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// Returns `true` when the directory at `path` with the given `name` should
    /// be skipped entirely (including its subtree).
    func shouldExclude(name: String, path: String) -> Bool {
        if excludedBasenames.contains(name) {
            return true
        }
        for i in excludedPathPrefixes.indices {
            if path == excludedPathPrefixes[i] || path.hasPrefix(_prefixesWithSlash[i]) {
                return true
            }
        }
        return false
    }
}

// MARK: - ScanExclusionManager

/// Central registry for scan exclusion rules.
///
/// All API is static. Mirrors the design of ``BlocklistManager`` for consistency.
enum ScanExclusionManager {

    // MARK: Built-in basenames

    /// Directory names that are excluded by default.
    /// These are development caches, dependency stores, and build artifacts
    /// that typically contain millions of small files with no user value.
    static let defaultBasenames: Set<String> = [
        // JavaScript / Node
        "node_modules", ".npm", ".yarn", ".pnpm-store",
        // Git
        ".git",
        // Kotlin / JVM
        ".konan", ".gradle", ".m2",
        // Xcode / Apple
        "DerivedData", "xcuserdata", ".swiftpm",
        // CocoaPods
        "Pods", ".cocoapods",
        // Rust
        ".cargo", ".rustup",
        // Python
        "__pycache__", ".venv", ".tox",
        // Swift Package Manager build
        ".build",
        // General caches
        ".cache", ".ccache",
        // Containers & VMs
        ".vagrant", ".docker",
        // Carthage
        "Carthage",
        // Dart / Flutter
        ".pub-cache",
    ]

    // MARK: Built-in path prefixes

    /// Absolute path prefixes excluded by default.
    /// Expanded at load time so `~` resolves to the current user's home.
    static let defaultPathPrefixes: [String] = {
        let home = NSHomeDirectory()
        return [
            // APFS firmlink volumes — content under /System/Volumes/Data is
            // already accessible via firmlinks at /. Scanning both paths
            // double-counts every file on the Data volume.
            "/System/Volumes/Data",
            "/System/Volumes/VM",
            "/System/Volumes/Preboot",
            "/System/Volumes/Update",
            "/System/Volumes/xarts",
            "/System/Volumes/iSCPreboot",
            "/System/Volumes/Hardware",

            // User Xcode build artifacts — large generated output, not user content.
            "\(home)/Library/Developer/Xcode/DerivedData",

            // ~/Library/Caches and CoreSimulator are removed from exclusions:
            // they contain real user data (simulator runtimes, app caches) that users
            // should be able to see in Spacie.
            // Simulator APFS sub-volumes (/Library/Developer/CoreSimulator/Volumes/*)
            // are on separate disk devices (disk5s1, disk7s1…) and are now stopped
            // naturally by the cross-device check (crossMountPoints: false).

            "/private/var/folders",
            "/private/var/db",

            // System temporary directories — contain OS/app session data with no
            // value for disk-usage analysis. /private/tmp is on the same device
            // as / so the cross-mount-point check does not exclude it automatically.
            "/private/tmp",
            "/tmp",
        ]
    }()

    // MARK: User exclusions file

    private static let exclusionsFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".spacie/scan-exclusions.txt")
    }()

    nonisolated(unsafe) private static var _lock = os_unfair_lock()
    nonisolated(unsafe) private static var _userExclusions: [String] = []
    nonisolated(unsafe) private static var _loaded = false

    static var userExclusions: [String] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        if !_loaded {
            _loaded = true
            _userExclusions = loadUserExclusions()
        }
        return _userExclusions
    }

    // MARK: Load / Save

    static func loadRules() -> ScanExclusionRules {
        let userLines = userExclusions
        var basenames = defaultBasenames
        var prefixes = defaultPathPrefixes

        for line in userLines {
            let expanded: String
            if line.hasPrefix("~") {
                expanded = (line as NSString).expandingTildeInPath
            } else {
                expanded = line
            }

            // If the pattern contains a `/` it's treated as a path prefix;
            // otherwise it's a basename match.
            if expanded.contains("/") {
                prefixes.append(expanded)
            } else {
                basenames.insert(expanded)
            }
        }

        return ScanExclusionRules(
            excludedBasenames: basenames,
            excludedPathPrefixes: prefixes
        )
    }

    private static func loadUserExclusions() -> [String] {
        guard FileManager.default.fileExists(atPath: exclusionsFileURL.path) else {
            return []
        }
        guard let content = try? String(contentsOf: exclusionsFileURL, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    private static func saveUserExclusions(_ patterns: [String]) throws {
        let dir = exclusionsFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = "# Spacie scan exclusions \u{2014} one pattern per line\n"
            + "# Lines starting with / or ~ are path prefixes; others are directory basenames\n"
            + patterns.joined(separator: "\n") + "\n"
        try content.write(to: exclusionsFileURL, atomically: true, encoding: .utf8)
        os_unfair_lock_lock(&_lock)
        _userExclusions = patterns
        os_unfair_lock_unlock(&_lock)
    }

    static func addExclusion(_ pattern: String) throws {
        var patterns = userExclusions
        guard !patterns.contains(pattern) else { return }
        patterns.append(pattern)
        try saveUserExclusions(patterns)
    }

    static func removeExclusion(_ pattern: String) throws {
        var patterns = userExclusions
        patterns.removeAll { $0 == pattern }
        try saveUserExclusions(patterns)
    }
}
