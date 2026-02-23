import Foundation

// MARK: - DuplicateGroup

struct DuplicateGroup: Identifiable, Sendable {
    let id: String // hash-based identifier
    let fileSize: UInt64
    let files: [DuplicateFile]
    let hashLevel: HashLevel

    /// Total space wasted (all copies except one)
    var wastedSpace: UInt64 {
        guard files.count > 1 else { return 0 }
        return fileSize * UInt64(files.count - 1)
    }

    var fileCount: Int { files.count }
}

// MARK: - DuplicateFile

struct DuplicateFile: Identifiable, Sendable, Hashable {
    let id: String // file path
    let url: URL
    let name: String
    let path: String
    let size: UInt64
    let modificationDate: Date
    var isSelected: Bool // selected for deletion

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DuplicateFile, rhs: DuplicateFile) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - HashLevel

enum HashLevel: Int, Sendable, Comparable {
    case sizeOnly = 0
    case partialHash = 1
    case fullHash = 2

    var displayName: String {
        switch self {
        case .sizeOnly: "Size Match"
        case .partialHash: "Partial Hash"
        case .fullHash: "Full Hash (Confirmed)"
        }
    }

    static func < (lhs: HashLevel, rhs: HashLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - DuplicateScanState

enum DuplicateScanState: Sendable, Equatable {
    case idle
    case groupingBySize
    case computingPartialHash(progress: Double)
    case computingFullHash(groupId: String, progress: Double)
    case completed(stats: DuplicateStats)
    case error(String)

    static func == (lhs: DuplicateScanState, rhs: DuplicateScanState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): true
        case (.groupingBySize, .groupingBySize): true
        case (.computingPartialHash(let a), .computingPartialHash(let b)): a == b
        case (.completed(let a), .completed(let b)): a == b
        default: false
        }
    }
}

// MARK: - DuplicateStats

struct DuplicateStats: Sendable, Equatable {
    let groupCount: Int
    let totalDuplicateFiles: Int
    let totalWastedSpace: UInt64
    let scanDuration: TimeInterval
}

// MARK: - AutoSelectStrategy

enum AutoSelectStrategy: String, Sendable, CaseIterable, Identifiable {
    case keepNewest = "newest"
    case keepOldest = "oldest"
    case keepShortestPath = "shortest"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepNewest: "Keep Newest"
        case .keepOldest: "Keep Oldest"
        case .keepShortestPath: "Keep Shortest Path"
        }
    }
}
