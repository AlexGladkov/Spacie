import Foundation

// MARK: - iTransferState

/// Strongly typed wizard state — replaces the previous combination of a flat
/// `iTransferStep` enum + a half-dozen independent boolean flags
/// (`isWaitingForSource`, `isWaitingForDestination`, `isLoadingApps`, …) that
/// the Sprint 4 audit flagged as "impossible-state bug class":
/// `isWaitingForSource && step == .selectApps` was representable in the old
/// VM but did not correspond to any valid wizard moment.
///
/// Each case carries the small substate the corresponding step view needs
/// (e.g. whether a connect-device polling loop is active). Cumulative wizard
/// data (selected apps, archive dir, source device after it's been chosen, …)
/// lives in [iTransferWizardData] so a step transition doesn't drop it.
enum iTransferState: Sendable {
    case dependencyCheck(DependencyCheckSubstate)
    case connectSource(ConnectDeviceSubstate)
    case selectApps(SelectAppsSubstate)
    case chooseAction
    case connectDestination(ConnectDeviceSubstate)
    case transferring
    case result

    /// Discrete step label, useful for back-compat callers that still depend
    /// on the original `iTransferStep` enum.
    var kind: iTransferStep {
        switch self {
        case .dependencyCheck: return .dependencyCheck
        case .connectSource: return .connectSource
        case .selectApps: return .selectApps
        case .chooseAction: return .chooseAction
        case .connectDestination: return .connectDestination
        case .transferring: return .transferring
        case .result: return .result
        }
    }
}

// MARK: - Substates

struct DependencyCheckSubstate: Sendable {
    var isInstallingDependencies: Bool = false
    var isCheckingAppleID: Bool = false
    var isAuthenticatingAppleID: Bool = false
}

struct ConnectDeviceSubstate: Sendable {
    /// True while the polling loop is active and a trusted device has not yet
    /// appeared. Mutually exclusive with the wizard moving past
    /// [iTransferStep.connectSource] or `connectDestination`.
    var isWaiting: Bool = false
}

struct SelectAppsSubstate: Sendable {
    var isLoadingApps: Bool = false
}

// MARK: - iTransferWizardData

/// Cumulative wizard data carried across step transitions.
///
/// Held as a single struct so that mutations to any field fire one
/// observation update on the view model rather than triggering N independent
/// `@Observable` setters.
struct iTransferWizardData: Sendable {

    // -- Step 1 / Apple ID --

    var dependencyStatus: DependencyStatus?
    var installOutput: [String] = []
    var appleIDAuthenticated: Bool = false
    var appleIDLoginError: String?
    var appleIDNeedsTwoFactor: Bool = false
    var appleIDEmailForTwoFactor: String = ""

    // -- Step 2 / Source device --

    var sourceDevice: DeviceInfo?
    var sourceTrustState: TrustState = .notTrusted

    // -- Step 3 / App selection --

    var availableApps: [AppInfo] = []
    var selectedBundleIDs: Set<String> = []

    // -- Step 4 / Action choice --

    /// `true` → archive only. `false` → archive + install on destination.
    var archiveOnly: Bool = false
    /// Directory selected by the user for storing IPAs. `nil` until chosen.
    var archiveDir: URL?

    // -- Step 5 / Destination device --

    var destinationDevice: DeviceInfo?
    var destinationTrustState: TrustState = .notTrusted

    // -- Step 6 / Transfer --

    var transferProgress: TransferProgress?

    // -- Step 7 / Result --

    var transferResult: TransferResult?

    // -- General error --

    var lastError: String?
}

// MARK: - Factories

extension iTransferWizardData {
    /// Default state for a freshly opened wizard. `archiveOnly` is `false` so
    /// the user explicitly opts into archive-only mode on the action step.
    static func initial() -> Self { Self() }

    /// State for re-entering the wizard after a completed transfer. Sets
    /// `archiveOnly = true` because the most common follow-up flow is to
    /// archive additional apps. Keep this divergence from `initial()`
    /// explicit so the difference doesn't drift.
    static func afterReset() -> Self {
        var data = Self()
        data.archiveOnly = true
        return data
    }
}
