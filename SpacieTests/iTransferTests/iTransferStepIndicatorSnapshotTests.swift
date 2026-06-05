import SwiftUI
import XCTest
import SnapshotTesting
@testable import Spacie

// MARK: - iTransferStepIndicatorSnapshotTests

/// Visual regression coverage for the wizard step-indicator using
/// `pointfreeco/swift-snapshot-testing` (added via SPM in Sprint 4.5).
///
/// Snapshots are recorded on first run (the test fails the first time and
/// stores the reference under `__Snapshots__/`). Re-record references by
/// setting `withSnapshotTesting(record: .all) { … }` around the assertions.
@MainActor
final class iTransferStepIndicatorSnapshotTests: XCTestCase {

    func testStepIndicator_dependencyCheckStep() {
        let host = renderHost(.dependencyCheck)
        assertSnapshot(of: host, as: .image)
    }

    func testStepIndicator_transferringStep() {
        let host = renderHost(.transferring)
        assertSnapshot(of: host, as: .image)
    }

    func testStepIndicator_resultStep() {
        let host = renderHost(.result)
        assertSnapshot(of: host, as: .image)
    }

    // MARK: - Helpers

    /// Wrap a SwiftUI view in an `NSHostingView` so the snapshot strategy has
    /// a concrete `NSView` to render — the default `.image` strategy doesn't
    /// support bare SwiftUI views on macOS.
    private func renderHost(_ step: iTransferStep) -> NSView {
        let view = iTransferStepIndicator(currentStep: step)
            .frame(width: 480, height: 60)
            .padding()
            .background(Color(white: 0.97))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 92)
        host.layoutSubtreeIfNeeded()
        return host
    }
}
