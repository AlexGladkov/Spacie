import Foundation
import SpacieKit

// MARK: - ScanExclusionRules

/// Immutable set of rules for excluding directories during a file system scan.
///
/// Two kinds of checks are performed:
/// 1. **Basename lookup** — O(1) `Set` membership test against known directory names.
/// 2. **Path prefix match** — linear scan over a small array of absolute path prefixes.
///
/// User-defined exclusions from `~/.spacie/scan-exclusions.txt` are merged at load time.
struct ScanExclusionRules: Sendable {

    let excludedBasenames: Set<String>
    let excludedPathPrefixes: [String]

    /// Pre-computed `excludedPathPrefixes[i] + "/"` strings.
    private let _prefixesWithSlash: [String]

    init(excludedBasenames: Set<String>, excludedPathPrefixes: [String]) {
        self.excludedBasenames = excludedBasenames
        self.excludedPathPrefixes = excludedPathPrefixes
        self._prefixesWithSlash = excludedPathPrefixes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// Returns `true` when the directory at `path` with the given `name` should
    /// be skipped entirely (including its subtree).
    /// Hot path — stays in Swift, no ObjC overhead.
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

    // MARK: Built-in basenames (from KMP)

    /// Directory names that are excluded by default. Source of truth: KMP `SpaScanExclusionRules`.
    static let defaultBasenames: Set<String> =
        SpaScanExclusionRules.companion.defaultBasenames

    // MARK: Built-in path prefixes (from KMP)

    /// Absolute path prefixes excluded by default. Source of truth: KMP `SpaScanExclusionRules`.
    static let defaultPathPrefixes: [String] = {
        let home = NSHomeDirectory()
        return SpaScanExclusionRules.companion.defaultPathPrefixes(home: home)
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
        let alreadyLoaded = _loaded
        let cached = _userExclusions
        os_unfair_lock_unlock(&_lock)

        if alreadyLoaded { return cached }

        // File I/O outside the lock
        let loaded = loadUserExclusions()

        os_unfair_lock_lock(&_lock)
        if !_loaded {
            _loaded = true
            _userExclusions = loaded
        }
        let result = _userExclusions
        os_unfair_lock_unlock(&_lock)
        return result
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
