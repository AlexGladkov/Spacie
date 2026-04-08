import Foundation

// MARK: - ToolPaths

/// Absolute filesystem paths to all required `libimobiledevice` CLI tools.
///
/// Populated by ``HomebrewResolver/resolveAll()`` once every tool has been
/// located on disk. All paths are guaranteed to point to executable files
/// at the time of resolution (though they may be removed later).
struct ToolPaths: Sendable {

    /// Absolute path to `idevice_id` — lists connected iOS device UDIDs.
    let ideviceId: String

    /// Absolute path to `ideviceinfo` — retrieves device information.
    let ideviceInfo: String

    /// Absolute path to `ideviceinstaller` — installs / uninstalls apps.
    let ideviceinstaller: String

    /// Absolute path to `idevicepair` — pairs / unpairs iOS devices.
    let idevicepair: String

    /// Absolute path to `brew` — the Homebrew package manager itself.
    ///
    /// Included so the UI can trigger `brew install libimobiledevice`
    /// if any tools are missing.
    let brew: String

    /// Absolute path to `ipatool` — downloads IPA files from the App Store.
    let ipatool: String
}

// MARK: - DependencyStatus

/// Result of a full dependency check performed by ``HomebrewResolver/resolveAll()``.
enum DependencyStatus: Sendable {

    /// All required tools are present and executable.
    case ready(ToolPaths)

    /// Homebrew is installed but one or more tools are missing.
    ///
    /// `tools` contains the CLI names (e.g. `["idevice_id", "ideviceinfo"]`)
    /// that could not be found in any of the known Homebrew prefixes.
    case missing(tools: [String])

    /// Homebrew itself is not installed on this machine.
    ///
    /// Without Homebrew the user cannot install `libimobiledevice`
    /// through the expected channel.
    case homebrewMissing
}

// MARK: - HomebrewResolver

/// Locates Homebrew-installed CLI tools by probing known absolute paths.
///
/// macOS ships with two conventional Homebrew prefixes:
/// - `/opt/homebrew/bin/` on Apple Silicon (arm64)
/// - `/usr/local/bin/` on Intel (x86_64)
///
/// ``HomebrewResolver`` checks these two prefixes **in order** for each tool
/// and caches the result so that repeated lookups are essentially free.
///
/// > Important: The resolver intentionally does **not** consult `$PATH` or
/// > invoke `which`. Shell environment variables are unreliable inside a
/// > sandboxed macOS app bundle, and shelling out to `which` introduces
/// > unnecessary latency and potential code-injection surface.
///
/// ## Usage
///
/// ```swift
/// let resolver = HomebrewResolver()
/// let status = await resolver.resolveAll()
/// switch status {
/// case .ready(let paths):
///     // Launch idevice_id at paths.ideviceId …
/// case .missing(let tools):
///     // Prompt user to install missing tools …
/// case .homebrewMissing:
///     // Direct user to https://brew.sh …
/// }
/// ```
///
/// ## Thread Safety
/// `HomebrewResolver` is an `actor`, so all mutable state (the cache) is
/// protected by Swift concurrency's actor isolation — no locks required.
actor HomebrewResolver {

    // MARK: - Constants

    /// Known Homebrew bin directories, ordered by probe priority.
    ///
    /// Apple Silicon is checked first because it is the dominant architecture
    /// for Macs manufactured since late 2020.
    private static let prefixes: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// CLI tool names that must all be present for full functionality.
    private static let requiredTools: [String] = [
        "idevice_id",
        "ideviceinfo",
        "ideviceinstaller",
        "idevicepair",
        "ipatool",
    ]

    // MARK: - Cache

    /// Resolved absolute paths keyed by tool name.
    ///
    /// A `nil` value means the tool was probed and not found.
    /// Absence from the dictionary means the tool has not been probed yet.
    private var cache: [String: String?] = [:]

    // MARK: - Public API

    /// Resolves a single tool by name.
    ///
    /// Probes `/opt/homebrew/bin/<toolName>` then `/usr/local/bin/<toolName>`,
    /// returning the first path that exists and is executable. The result is
    /// cached for the lifetime of this actor (or until ``invalidateCache()``
    /// is called).
    ///
    /// - Parameter toolName: The bare CLI name, e.g. `"idevice_id"`.
    /// - Returns: The absolute path to the executable, or `nil` if not found.
    func resolve(_ toolName: String) async -> String? {
        if let cached = cache[toolName] {
            return cached
        }

        let resolved = probeToolOnDisk(toolName)
        cache[toolName] = resolved
        return resolved
    }

    /// Returns `true` if a Homebrew `brew` executable exists at either
    /// known prefix.
    ///
    /// This is a lightweight check that does **not** invoke `brew` — it only
    /// verifies the binary is present and executable.
    func isHomebrewInstalled() async -> Bool {
        await resolve("brew") != nil
    }

    /// Resolves all required `libimobiledevice` tools in one pass.
    ///
    /// - Returns: ``DependencyStatus/ready(_:)`` if every tool (plus `brew`)
    ///   is found, ``DependencyStatus/missing(tools:)`` if Homebrew is present
    ///   but some tools are absent, or ``DependencyStatus/homebrewMissing`` if
    ///   Homebrew itself cannot be located.
    func resolveAll() async -> DependencyStatus {
        // Resolve brew first — if it's absent, nothing else matters.
        guard let brewPath = await resolve("brew") else {
            return .homebrewMissing
        }

        // Resolve each required tool, collecting any that are missing.
        var missingTools: [String] = []
        var resolvedPaths: [String: String] = [:]

        for tool in Self.requiredTools {
            if let path = await resolve(tool) {
                resolvedPaths[tool] = path
            } else {
                missingTools.append(tool)
            }
        }

        guard missingTools.isEmpty else {
            return .missing(tools: missingTools)
        }

        let paths = ToolPaths(
            ideviceId: resolvedPaths["idevice_id"]!,
            ideviceInfo: resolvedPaths["ideviceinfo"]!,
            ideviceinstaller: resolvedPaths["ideviceinstaller"]!,
            idevicepair: resolvedPaths["idevicepair"]!,
            brew: brewPath,
            ipatool: resolvedPaths["ipatool"]!
        )

        return .ready(paths)
    }

    /// Clears all cached resolutions.
    ///
    /// Call this after the user runs `brew install` so that subsequent
    /// ``resolve(_:)`` / ``resolveAll()`` calls re-probe the filesystem.
    func invalidateCache() {
        cache.removeAll()
    }

    // MARK: - Private

    /// Probes known Homebrew prefixes for an executable file named `toolName`.
    ///
    /// - Parameter toolName: The bare CLI name (e.g. `"idevice_id"`).
    /// - Returns: The first matching absolute path, or `nil`.
    private func probeToolOnDisk(_ toolName: String) -> String? {
        let fileManager = FileManager.default

        for prefix in Self.prefixes {
            let candidate = "\(prefix)/\(toolName)"
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}
