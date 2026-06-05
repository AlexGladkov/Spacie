import SwiftUI

// TransferPhase → user-facing label + colour.

// MARK: - TransferPhase Label

extension TransferPhase {
    /// User-facing localised phase label used by ``TransferringStepView``.
    var label: String {
        switch self {
        case .pending: return "Queued"
        case .extracting: return "Extracting…"
        case .archiving: return "Archiving…"
        case .installing: return "Installing…"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
}
