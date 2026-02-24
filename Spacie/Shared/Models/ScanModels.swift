import Foundation

// MARK: - ScanPhase

/// Identifies the current phase of a two-phase scan.
///
/// - ``red``: Phase 1 in progress (shallow directory-only traversal).
/// - ``yellow``: Phase 1 complete, Phase 2 in progress (deep per-folder scan).
/// - ``smartGreen``: Coverage threshold reached, partial scan with virtual "Other" node.
/// - ``green``: Phase 2 complete, all data accurate.
enum ScanPhase: Sendable, Equatable {
    case red
    case yellow
    case smartGreen
    case green
}

// MARK: - ScanState

enum ScanState: Sendable, Equatable {
    case idle
    case scanning(ScanProgress)
    case completed(ScanStats)
    case cancelled
    case error(String)

    var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

// MARK: - ScanProgress

struct ScanProgress: Sendable, Equatable {
    let filesScanned: UInt64
    let directoriesScanned: UInt64
    let skippedDirectories: UInt64
    let totalLogicalSizeScanned: UInt64
    let totalPhysicalSizeScanned: UInt64
    let currentPath: String
    let elapsedTime: TimeInterval
    let estimatedTotalFiles: UInt64? // nil if unknown
    let phase: ScanPhase
    let deepScanProgress: Double?      // nil in Red, 0.0-1.0 in Yellow
    let deepScanDirsCompleted: UInt64
    let deepScanDirsTotal: UInt64
    /// Smart Scan coverage percentage (nil when not in smart scan mode or during Red phase).
    let coveragePercent: Double?
    /// Total bytes scanned so far during smart scan.
    let scannedBytes: UInt64
    /// Estimated total used space on the volume (totalSize - freeSize).
    let estimatedUsedSpace: UInt64

    init(
        filesScanned: UInt64,
        directoriesScanned: UInt64,
        skippedDirectories: UInt64,
        totalLogicalSizeScanned: UInt64,
        totalPhysicalSizeScanned: UInt64,
        currentPath: String,
        elapsedTime: TimeInterval,
        estimatedTotalFiles: UInt64?,
        phase: ScanPhase = .red,
        deepScanProgress: Double? = nil,
        deepScanDirsCompleted: UInt64 = 0,
        deepScanDirsTotal: UInt64 = 0,
        coveragePercent: Double? = nil,
        scannedBytes: UInt64 = 0,
        estimatedUsedSpace: UInt64 = 0
    ) {
        self.filesScanned = filesScanned
        self.directoriesScanned = directoriesScanned
        self.skippedDirectories = skippedDirectories
        self.totalLogicalSizeScanned = totalLogicalSizeScanned
        self.totalPhysicalSizeScanned = totalPhysicalSizeScanned
        self.currentPath = currentPath
        self.elapsedTime = elapsedTime
        self.estimatedTotalFiles = estimatedTotalFiles
        self.phase = phase
        self.deepScanProgress = deepScanProgress
        self.deepScanDirsCompleted = deepScanDirsCompleted
        self.deepScanDirsTotal = deepScanDirsTotal
        self.coveragePercent = coveragePercent
        self.scannedBytes = scannedBytes
        self.estimatedUsedSpace = estimatedUsedSpace
    }

    /// Returns the appropriate size based on the display mode.
    func totalSizeScanned(for mode: SizeMode) -> UInt64 {
        switch mode {
        case .logical: totalLogicalSizeScanned
        case .physical: totalPhysicalSizeScanned
        }
    }

    var estimatedProgress: Double? {
        guard let total = estimatedTotalFiles, total > 0 else { return nil }
        return min(1.0, Double(filesScanned) / Double(total))
    }

    var filesPerSecond: Double {
        guard elapsedTime > 0 else { return 0 }
        return Double(filesScanned) / elapsedTime
    }

    static func == (lhs: ScanProgress, rhs: ScanProgress) -> Bool {
        lhs.filesScanned == rhs.filesScanned
    }
}

// MARK: - ScanStats

struct ScanStats: Sendable, Equatable {
    let totalFiles: UInt64
    let totalDirectories: UInt64
    let totalLogicalSize: UInt64
    let totalPhysicalSize: UInt64
    let restrictedDirectories: UInt64
    let skippedDirectories: UInt64
    let scanDuration: TimeInterval
    let volumeId: String

    var filesPerSecond: Double {
        guard scanDuration > 0 else { return 0 }
        return Double(totalFiles) / scanDuration
    }
}

// MARK: - ScanEvent

enum ScanEvent: Sendable {
    case directoryEntered(path: String, depth: Int)
    case fileFound(node: RawFileNode)
    case directoryCompleted(path: String, totalSize: UInt64)
    case directorySkipped(path: String, depth: Int)
    case progress(ScanProgress)
    case restricted(path: String)
    case error(path: String, code: Int32, message: String)
    case completed(stats: ScanStats)
}

// MARK: - ScanConfiguration

struct ScanConfiguration: Sendable {
    let rootPath: URL
    let volumeId: String
    let followSymlinks: Bool
    let crossMountPoints: Bool
    let includeHidden: Bool
    let batchSize: Int
    let throttleInterval: TimeInterval // for UI updates
    let exclusionRules: ScanExclusionRules

    init(
        rootPath: URL,
        volumeId: String,
        followSymlinks: Bool = false,
        crossMountPoints: Bool = false,
        includeHidden: Bool = true,
        batchSize: Int = 1000,
        throttleInterval: TimeInterval = 0.1,
        exclusionRules: ScanExclusionRules = ScanExclusionManager.loadRules()
    ) {
        self.rootPath = rootPath
        self.volumeId = volumeId
        self.followSymlinks = followSymlinks
        self.crossMountPoints = crossMountPoints
        self.includeHidden = includeHidden
        self.batchSize = batchSize
        self.throttleInterval = throttleInterval
        self.exclusionRules = exclusionRules
    }
}

// MARK: - SizeMode

enum SizeMode: String, Sendable, CaseIterable, Identifiable {
    case logical = "logical"
    case physical = "physical"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .logical: "Logical Size"
        case .physical: "Disk Usage"
        }
    }
}

// MARK: - VisualizationMode

enum VisualizationMode: String, Sendable, CaseIterable, Identifiable {
    case sunburst = "sunburst"
    case treemap = "treemap"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sunburst: "Sunburst"
        case .treemap: "Treemap"
        }
    }

    var systemImage: String {
        switch self {
        case .sunburst: "circle.circle"
        case .treemap: "square.grid.2x2"
        }
    }
}

// MARK: - ScanProfileType

/// Predefined scan profile that determines Tier 1 priority paths for Smart Scan.
enum ScanProfileType: String, Codable, Sendable, CaseIterable, Identifiable {
    case `default` = "default"
    case developer = "developer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: "Default"
        case .developer: "Developer"
        }
    }
}

// MARK: - SmartScanSettings

/// User-configurable settings for the Smart Scan feature.
struct SmartScanSettings: Codable, Sendable, Equatable {
    /// Whether Smart Scan is enabled. When disabled, a full scan is performed.
    var isEnabled: Bool = true
    /// The active scan profile determining Tier 1 priority paths.
    var profile: ScanProfileType = .default
    /// Coverage threshold at which the scan can stop early (0.0-1.0).
    var coverageThreshold: Double = 0.95

    /// Threshold below which an automatic incremental rescan is triggered after deletion.
    /// Uses hysteresis to prevent oscillation: `max(0.80, coverageThreshold - 0.05)`.
    var rescanTriggerThreshold: Double {
        max(0.80, coverageThreshold - 0.05)
    }
}

// MARK: - SmartScanResult

/// Summary of a completed Smart Scan pass.
struct SmartScanResult: Sendable {
    /// Percentage of estimated used space that was scanned (0.0-1.0).
    let coveragePercent: Double
    /// Total bytes accounted for by deep-scanned directories.
    let scannedBytes: UInt64
    /// Estimated total used space on the volume (totalSize - freeSize).
    let estimatedUsedSpace: UInt64
    /// Number of directories that were not scanned.
    let unscannedDirectoryCount: Int
}
