import Foundation

// MARK: - BlocklistManager

/// Manages the blocklist of protected file paths that Spacie cannot delete.
///
/// All API is static. This type is a namespace for blocklist logic
/// and does not require instantiation.
final class BlocklistManager: Sendable {

    // MARK: Hardcoded protected paths (cannot be deleted EVER)

    static let sipProtectedPaths: Set<String> = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/var",
        "/Library",
        "/private/var",
        "/private/etc",
    ]

    static let criticalUserPaths: Set<String> = {
        let home = NSHomeDirectory()
        return [
            "\(home)/.ssh",
            "\(home)/Library/Keychains",
            "\(home)/Library/Cookies",
        ]
    }()

    // MARK: Warning paths (can delete with confirmation)

    static let warningPatterns: [String] = [
        ".*/.zshrc",
        ".*/.bashrc",
        ".*/.bash_profile",
        ".*/.gitconfig",
        ".*/.gitignore_global",
        ".*/Library/Preferences",
        ".*\\.app$",
    ]

    // MARK: User blocklist

    private static let blocklistFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".spacie/blocklist.txt")
    }()

    nonisolated(unsafe) private static var _lock = os_unfair_lock()
    nonisolated(unsafe) private static var _userPatterns: [String] = []
    nonisolated(unsafe) private static var _loaded = false

    static var userPatterns: [String] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        if !_loaded {
            _loaded = true
            _userPatterns = loadUserBlocklist()
        }
        return _userPatterns
    }

    // MARK: Check methods

    enum DeletePermission: Sendable {
        case allowed
        case blocked(reason: String)
        case warning(reason: String)
    }

    static func checkPermission(for path: String) -> DeletePermission {
        // Check SIP-protected
        for sipPath in sipProtectedPaths {
            if path == sipPath || path.hasPrefix(sipPath + "/") {
                return .blocked(reason: "System Integrity Protection: \(sipPath)")
            }
        }

        // Check critical user paths
        for criticalPath in criticalUserPaths {
            if path == criticalPath || path.hasPrefix(criticalPath + "/") {
                return .blocked(reason: "Critical system file: \(criticalPath)")
            }
        }

        // Check user blocklist
        for pattern in userPatterns {
            if matchesGlob(path: path, pattern: pattern) {
                return .blocked(reason: "User blocklist: \(pattern)")
            }
        }

        // Check warning paths
        for pattern in warningPatterns {
            if matchesRegex(path: path, pattern: pattern) {
                return .warning(reason: "This file may be important. Proceed with caution.")
            }
        }

        return .allowed
    }

    // MARK: User blocklist file management

    static func loadUserBlocklist() -> [String] {
        guard FileManager.default.fileExists(atPath: blocklistFileURL.path) else {
            return []
        }
        guard let content = try? String(contentsOf: blocklistFileURL, encoding: .utf8) else {
            return []
        }
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func saveUserBlocklist(_ patterns: [String]) throws {
        let dir = blocklistFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let content = "# Spacie blocklist — one glob pattern per line\n" +
            patterns.joined(separator: "\n") + "\n"
        try content.write(to: blocklistFileURL, atomically: true, encoding: .utf8)
        os_unfair_lock_lock(&_lock)
        _userPatterns = patterns
        os_unfair_lock_unlock(&_lock)
    }

    static func addPattern(_ pattern: String) throws {
        var patterns = userPatterns
        guard !patterns.contains(pattern) else { return }
        patterns.append(pattern)
        try saveUserBlocklist(patterns)
    }

    static func removePattern(_ pattern: String) throws {
        var patterns = userPatterns
        patterns.removeAll { $0 == pattern }
        try saveUserBlocklist(patterns)
    }

    // MARK: Glob matching

    private static func matchesGlob(path: String, pattern: String) -> Bool {
        let expandedPattern: String
        if pattern.hasPrefix("~") {
            expandedPattern = (pattern as NSString).expandingTildeInPath
        } else {
            expandedPattern = pattern
        }

        // Convert glob to regex-like matching
        // Simple implementation: ** matches any path, * matches within segment
        let regexPattern = expandedPattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: "<<<DOUBLESTAR>>>")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "<<<DOUBLESTAR>>>", with: ".*")

        return matchesRegex(path: path, pattern: "^\(regexPattern)")
    }

    private static func matchesRegex(path: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
    }
}
