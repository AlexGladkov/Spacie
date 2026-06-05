import Foundation
import SpacieKit

// MARK: - ScanProfile

/// Thin wrapper delegating Tier 1 path resolution to KMP `SpaSpacieFactory`.
enum ScanProfile {

    /// Returns filtered Tier 1 paths for the given profile type.
    /// Paths that don't exist on disk are already filtered by KMP.
    static func tier1Paths(for profileType: ScanProfileType) -> [String] {
        let kmpType = profileType.toKMP()
        return SpaSpacieFactory.shared.defaultScanProfilePaths(profileType: kmpType)
    }
}

// MARK: - ScanProfileType → KMP

extension ScanProfileType {

    func toKMP() -> SpaScanProfileType {
        switch self {
        case .default: .default_
        case .developer: .developer
        }
    }
}
