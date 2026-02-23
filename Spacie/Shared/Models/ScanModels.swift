import Foundation

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
    let totalSizeScanned: UInt64
    let currentPath: String
    let elapsedTime: TimeInterval
    let estimatedTotalFiles: UInt64? // nil if unknown

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

    init(
        rootPath: URL,
        volumeId: String,
        followSymlinks: Bool = false,
        crossMountPoints: Bool = false,
        includeHidden: Bool = true,
        batchSize: Int = 1000,
        throttleInterval: TimeInterval = 0.1
    ) {
        self.rootPath = rootPath
        self.volumeId = volumeId
        self.followSymlinks = followSymlinks
        self.crossMountPoints = crossMountPoints
        self.includeHidden = includeHidden
        self.batchSize = batchSize
        self.throttleInterval = throttleInterval
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
