import Foundation

// MARK: - ToolPaths

/// Absolute filesystem paths to all required `libimobiledevice` CLI tools.
struct ToolPaths: Sendable {
    let ideviceId: String
    let ideviceInfo: String
    let ideviceinstaller: String
    let idevicepair: String
    let brew: String
    let ipatool: String
}

// MARK: - DependencyStatus

/// Result of a full dependency check.
enum DependencyStatus: Sendable {
    /// All required tools are present and executable.
    case ready(ToolPaths)
    /// Homebrew is installed but one or more tools are missing.
    case missing(tools: [String])
    /// Homebrew itself is not installed on this machine.
    case homebrewMissing
}
