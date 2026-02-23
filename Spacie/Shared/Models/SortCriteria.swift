import Foundation

// MARK: - SortCriteria

enum SortCriteria: String, Sendable, CaseIterable, Identifiable {
    case size = "size"
    case name = "name"
    case date = "date"
    case type = "type"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        case .date: "Date Modified"
        case .type: "Type"
        }
    }
}

// MARK: - TreeSortOrder

/// Sort order used by ``FileTree`` for sorting children by criteria.
/// Distinct from the `SortOrder` type in LargeFilesView/OldFilesView which
/// uses a `Field` enum for UI-level file list sorting.
struct TreeSortOrder: Sendable, Equatable {
    var criteria: SortCriteria
    var ascending: Bool

    static let sizeDescending = TreeSortOrder(criteria: .size, ascending: false)
    static let nameAscending = TreeSortOrder(criteria: .name, ascending: true)
    static let dateDescending = TreeSortOrder(criteria: .date, ascending: false)
    static let typeAscending = TreeSortOrder(criteria: .type, ascending: true)

    /// Convenience shorthand for descending size sort (used by visualization).
    static let size = TreeSortOrder.sizeDescending

    mutating func toggle(criteria newCriteria: SortCriteria) {
        if criteria == newCriteria {
            ascending.toggle()
        } else {
            criteria = newCriteria
            ascending = newCriteria == .name || newCriteria == .type
        }
    }
}

