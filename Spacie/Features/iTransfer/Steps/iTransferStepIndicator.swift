import SwiftUI

// Step indicator + sub-views.

// MARK: - Step Indicator

struct iTransferStepIndicator: View {

    let currentStep: iTransferStep

    private let steps: [(iTransferStep, String)] = [
        (.dependencyCheck, "Setup"),
        (.connectSource, "Source"),
        (.selectApps, "Apps"),
        (.chooseAction, "Action"),
        (.connectDestination, "Destination"),
        (.transferring, "Transfer"),
        (.result, "Done"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, pair in
                let (stepCase, label) = pair
                StepDot(
                    label: label,
                    number: index + 1,
                    state: dotState(for: stepCase)
                )
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(stepCase < currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func dotState(for step: iTransferStep) -> StepDot.State {
        if step < currentStep { return .done }
        if step == currentStep { return .active }
        return .pending
    }
}

struct StepDot: View {

    enum State { case done, active, pending }

    let label: String
    let number: Int
    let state: State

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(fillColor)
                    .frame(width: 28, height: 28)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(state == .pending ? .secondary : .primary)
        }
    }

    private var fillColor: Color {
        switch state {
        case .done: return .accentColor
        case .active: return .accentColor
        case .pending: return Color.secondary.opacity(0.2)
        }
    }
}
