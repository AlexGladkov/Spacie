import Foundation

// MARK: - ScanProfile

/// Provides predefined Tier 1 directory paths for Smart Scan prioritization.
///
/// Each ``ScanProfileType`` maps to a curated list of known "heavy" directories
/// on macOS. These paths are scanned first during Phase 2, before falling back
/// to Tier 2 (remaining directories sorted by cached size or entry count).
///
/// Non-existent paths are filtered out automatically, making profiles safe to use
/// in sandboxed environments where some system paths may be inaccessible.
enum ScanProfile {

    // MARK: Public API

    /// Returns filtered Tier 1 paths for the given profile type.
    ///
    /// Paths are expanded from `~` using `NSHomeDirectory()` and filtered
    /// to include only those that exist on disk.
    ///
    /// - Parameter profileType: The active scan profile.
    /// - Returns: Array of absolute path strings that exist on the current system.
    static func tier1Paths(for profileType: ScanProfileType) -> [String] {
        let candidates: [String]
        switch profileType {
        case .default:
            candidates = defaultPaths
        case .developer:
            candidates = defaultPaths + developerPaths
        }

        let fileManager = FileManager.default
        return candidates.filter { fileManager.fileExists(atPath: $0) }
    }

    // MARK: - Private Path Definitions

    /// Universal macOS paths present on 95%+ of systems.
    private static var defaultPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Caches",
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Mail",
            "\(home)/Library/Messages",
            "\(home)/Downloads",
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Pictures",
            "/Applications",
            "/Library/Caches",
            "/System/Library",
            "/private/var",
        ]
    }

    /// Additional paths for developer workstations (Xcode, Android, package managers, etc.).
    private static var developerPaths: [String] {
        let home = NSHomeDirectory()
        return [
            // Xcode
            "\(home)/Library/Developer/Xcode/DerivedData",
            "\(home)/Library/Developer/Xcode/Archives",
            "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
            "\(home)/Library/Developer/CoreSimulator",
            // Android
            "\(home)/Library/Android/sdk",
            // Package managers & toolchains
            "\(home)/.gradle",
            "\(home)/.cocoapods",
            "\(home)/.pub-cache",
            "\(home)/.cargo",
            "\(home)/.rustup",
            "\(home)/.npm",
            "\(home)/.yarn",
            "\(home)/.pnpm-store",
            // Homebrew (Intel + ARM)
            "/usr/local/Cellar",
            "/opt/homebrew/Cellar",
            // Docker Desktop
            "\(home)/Library/Application Support/Docker/Data",
        ]
    }
}
