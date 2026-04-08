import SwiftUI

// MARK: - iTransferView

/// Root view for the iOS App Transfer wizard.
///
/// Renders the appropriate step view based on ``iTransferViewModel/step``.
/// Navigation between steps is driven exclusively by the view model —
/// the view never advances the step directly.
struct iTransferView: View {

    @State private var viewModel = iTransferViewModel()
    @State private var showArchiveLibrary = false
    var onDismiss: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            iTransferStepIndicator(currentStep: viewModel.step)
                .padding(.horizontal, 32)
                .padding(.top, 20)

            Divider()
                .padding(.top, 12)

            // Active step
            Group {
                switch viewModel.step {
                case .dependencyCheck:
                    DependencyCheckStepView(viewModel: viewModel)
                case .connectSource:
                    ConnectDeviceStepView(
                        title: "Connect Source iPhone",
                        subtitle: "Connect the iPhone you want to transfer apps FROM.",
                        device: viewModel.sourceDevice,
                        trustState: viewModel.sourceTrustState,
                        isWaiting: viewModel.isWaitingForSource,
                        onStart: { viewModel.startSourceDeviceObservation() }
                    )
                case .selectApps:
                    SelectAppsStepView(viewModel: viewModel)
                case .chooseAction:
                    ChooseActionStepView(viewModel: viewModel)
                case .connectDestination:
                    ConnectDeviceStepView(
                        title: "Connect Destination iPhone",
                        subtitle: "Connect the iPhone you want to transfer apps TO.",
                        device: viewModel.destinationDevice,
                        trustState: viewModel.destinationTrustState,
                        isWaiting: viewModel.isWaitingForDestination,
                        onStart: { viewModel.startDestinationDeviceObservation() }
                    )
                case .transferring:
                    TransferringStepView(viewModel: viewModel)
                case .result:
                    ResultStepView(
                        viewModel: viewModel,
                        onDismiss: {
                            viewModel.reset()
                            onDismiss?()
                        },
                        onShowArchive: {
                            showArchiveLibrary = true
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        }
        .navigationTitle("iOS Transfer")
        .toolbar {
            if let onDismiss {
                ToolbarItem(placement: .navigation) {
                    Button {
                        viewModel.stopDeviceObservation()
                        onDismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showArchiveLibrary = true
                } label: {
                    Label("Archive Library", systemImage: "archivebox")
                }
                .help("Browse archived IPA files")
            }
        }
        .sheet(isPresented: $showArchiveLibrary) {
            AppArchiveView()
                .frame(minWidth: 700, minHeight: 420)
        }
        .task {
            await viewModel.checkDependencies()
        }
    }
}

// MARK: - Step Indicator

private struct iTransferStepIndicator: View {

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

private struct StepDot: View {

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

// MARK: - Step 1: Dependency Check

private struct DependencyCheckStepView: View {

    @Bindable var viewModel: iTransferViewModel

    // Apple ID sign-in form state
    @State private var appleIDEmail = ""
    @State private var appleIDPassword = ""
    @State private var appleIDCode = ""
    @State private var showAppleIDForm = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            switch viewModel.dependencyStatus {
            case nil:
                ProgressView("Checking for libimobiledevice…")
                    .progressViewStyle(.circular)

            case .ready:
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.green)
                        Text("All tools installed")
                            .font(.title3.weight(.medium))
                    }

                    appleIDSection
                }

            case .homebrewMissing:
                VStack(spacing: 16) {
                    Text("Homebrew Not Found")
                        .font(.title3.weight(.semibold))
                    Text("Install Homebrew first, then relaunch Spacie.\n\nOpen Terminal and run:")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Text("/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
                        .font(.system(.caption, design: .monospaced))
                        .padding(10)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .textSelection(.enabled)
                    Button("Retry") {
                        Task { await viewModel.checkDependencies() }
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .missing(let tools):
                VStack(spacing: 16) {
                    Text("Missing Tools")
                        .font(.title3.weight(.semibold))
                    Text("The following tools need to be installed: \(tools.joined(separator: ", "))")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if viewModel.isInstallingDependencies {
                        installProgress
                    } else {
                        VStack(spacing: 8) {
                            Button("Install via Homebrew") {
                                Task { await viewModel.installDependencies() }
                            }
                            .buttonStyle(.borderedProminent)

                            if let error = viewModel.lastError {
                                Text(error)
                                    .foregroundStyle(.red)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 400)
                            }
                        }
                    }
                }
            }


            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Apple ID Section

    @ViewBuilder
    private var appleIDSection: some View {
        VStack(spacing: 12) {
            Divider()

            if viewModel.isCheckingAppleID {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking Apple ID…")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else if viewModel.appleIDAuthenticated {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Apple ID connected")
                        .font(.callout.weight(.medium))
                }
            } else if showAppleIDForm {
                appleIDForm
            } else {
                VStack(spacing: 8) {
                    Text("Apple ID required to download IPAs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Sign in with Apple ID") {
                        showAppleIDForm = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var appleIDForm: some View {
        if viewModel.appleIDNeedsTwoFactor {
            twoFactorForm
        } else {
            credentialsForm
        }
    }

    @ViewBuilder
    private var credentialsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in with Apple ID")
                .font(.subheadline.weight(.semibold))

            TextField("Email", text: $appleIDEmail)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()

            SecureField("Password", text: $appleIDPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)

            if let loginError = viewModel.appleIDLoginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    showAppleIDForm = false
                    appleIDEmail = ""
                    appleIDPassword = ""
                    appleIDCode = ""
                    viewModel.appleIDLoginError = nil
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task {
                        await viewModel.loginAppleID(email: appleIDEmail, password: appleIDPassword)
                        if viewModel.appleIDAuthenticated {
                            showAppleIDForm = false
                        }
                    }
                } label: {
                    if viewModel.isAuthenticatingAppleID {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Signing in…")
                        }
                    } else {
                        Text("Sign in")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appleIDEmail.isEmpty || appleIDPassword.isEmpty || viewModel.isAuthenticatingAppleID)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var twoFactorForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Color.accentColor)
                Text("Two-Factor Authentication")
                    .font(.subheadline.weight(.semibold))
            }

            Text("Apple sent a verification code to \(viewModel.appleIDEmailForTwoFactor.isEmpty ? "your devices" : viewModel.appleIDEmailForTwoFactor). Enter it below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Verification code", text: $appleIDCode)
                .textFieldStyle(.roundedBorder)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()

            if let loginError = viewModel.appleIDLoginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Back") {
                    viewModel.cancelAppleIDLogin()
                    appleIDCode = ""
                }
                .buttonStyle(.bordered)

                Spacer()

                Button {
                    Task {
                        await viewModel.loginAppleIDWithTwoFactor(
                            email: viewModel.appleIDEmailForTwoFactor,
                            password: appleIDPassword,
                            code: appleIDCode
                        )
                        if viewModel.appleIDAuthenticated {
                            showAppleIDForm = false
                        }
                    }
                } label: {
                    if viewModel.isAuthenticatingAppleID {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Verifying…")
                        }
                    } else {
                        Text("Verify")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appleIDCode.isEmpty || viewModel.isAuthenticatingAppleID)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    // MARK: - Install Progress

    @ViewBuilder
    private var installProgress: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing via Homebrew…")
                    .font(.callout.weight(.medium))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.installOutput.indices, id: \.self) { i in
                            Text(viewModel.installOutput[i])
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.7))
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 140)
                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.installOutput.count) { _, count in
                    if count > 0 {
                        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// MARK: - Steps 2 & 5: Connect Device

private struct ConnectDeviceStepView: View {

    let title: String
    let subtitle: String
    let device: DeviceInfo?
    let trustState: TrustState
    let isWaiting: Bool
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "iphone.and.arrow.right.and.arrow.left.inward")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let device {
                deviceCard(device: device)
            } else if isWaiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for device…")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Start Waiting for Device") {
                    onStart()
                }
                .buttonStyle(.borderedProminent)
            }

            if trustState == .notTrusted, device != nil {
                trustInstructions
            } else if trustState == .dialogShown {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you to tap \"Trust\" on the iPhone…")
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .onAppear { if !isWaiting { onStart() } }
    }

    private func deviceCard(device: DeviceInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName)
                    .font(.headline)
                Text("\(device.productType) · iOS \(device.productVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trustBadge
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var trustBadge: some View {
        switch trustState {
        case .trusted:
            Label("Trusted", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .dialogShown:
            Label("Waiting…", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.orange)
        case .notTrusted:
            Label("Not Trusted", systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var trustInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Trust Required", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
            Text("1. Unlock your iPhone.\n2. Tap **Trust** when the \"Trust This Computer?\" dialog appears.\n3. Enter your iPhone passcode if prompted.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 360)
    }
}

// MARK: - Step 3: Select Apps

private struct SelectAppsStepView: View {

    @Bindable var viewModel: iTransferViewModel
    @State private var sortOrder = [KeyPathComparator(\AppInfo.displayName)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Select Apps to Transfer")
                    .font(.title2.weight(.semibold))
                Spacer()
                if viewModel.isLoadingApps {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(viewModel.selectedBundleIDs.count) of \(viewModel.availableApps.count) selected")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Button("All") { viewModel.selectAllApps() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("None") { viewModel.deselectAllApps() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            if viewModel.isLoadingApps {
                Spacer()
                ProgressView("Loading app list…")
                    .progressViewStyle(.circular)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if viewModel.availableApps.isEmpty {
                if let error = viewModel.lastError {
                    ContentUnavailableView(
                        "Failed to Load Apps",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else {
                    ContentUnavailableView(
                        "No User Apps Found",
                        systemImage: "tray",
                        description: Text("No user-installed apps were found on this device.")
                    )
                }
            } else {
                Table(viewModel.availableApps, sortOrder: $sortOrder) {
                    TableColumn("") { app in
                        Toggle("", isOn: Binding(
                            get: { viewModel.selectedBundleIDs.contains(app.bundleID) },
                            set: { _ in viewModel.toggleAppSelection(app.bundleID) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    }
                    .width(28)

                    TableColumn("App", value: \.displayName) { app in
                        HStack(spacing: 8) {
                            Image(systemName: "app.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.displayName)
                                    .font(.callout)
                                Text(app.bundleID)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    TableColumn("Version", value: \.shortVersion) { app in
                        Text(app.shortVersion)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .width(80)

                    TableColumn("Size") { app in
                        Text(app.ipaSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .width(80)
                }
                .onChange(of: sortOrder) {
                    viewModel.availableApps.sort(using: sortOrder)
                }
            }

            HStack {
                Spacer()
                Button("Continue") {
                    viewModel.step = .chooseAction
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canProceedFromSelectApps)
            }
        }
    }
}

// MARK: - Step 4: Choose Action

private struct ChooseActionStepView: View {

    @Bindable var viewModel: iTransferViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Text("What would you like to do?")
                .font(.title2.weight(.semibold))

            HStack(spacing: 16) {
                ActionCard(
                    icon: "tray.and.arrow.down.fill",
                    title: "Archive Only",
                    description: "Save \(viewModel.selectedAppsCount) IPA file(s) to a local folder on this Mac.",
                    isSelected: viewModel.archiveOnly
                ) {
                    viewModel.chooseArchiveOnly()
                }

                ActionCard(
                    icon: "iphone.and.arrow.right.and.arrow.left.inward",
                    title: "Archive + Install",
                    description: "Save IPA(s) locally AND install them on another iPhone.",
                    isSelected: !viewModel.archiveOnly
                ) {
                    viewModel.chooseArchiveAndInstall()
                }
            }
            .frame(maxWidth: 600)

            // Archive directory picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Archive Location")
                    .font(.subheadline.weight(.medium))
                HStack {
                    Text(viewModel.archiveDir?.path ?? "Default: ~/Library/Application Support/Spacie/Archives")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        viewModel.selectArchiveDirectory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: 500)

            Button("Continue") {
                viewModel.proceedFromChooseAction()
            }
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ActionCard: View {

    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(isSelected ? 0.15 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step 6: Transferring

private struct TransferringStepView: View {

    @Bindable var viewModel: iTransferViewModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Transferring Apps")
                .font(.title2.weight(.semibold))

            if let progress = viewModel.transferProgress {
                ProgressView(value: progress.overallProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 480)

                Text("\(progress.completedCount + progress.failedCount) of \(progress.totalCount) apps")
                    .foregroundStyle(.secondary)

                List(progress.items) { item in
                    TransferItemRow(item: item)
                }
                .listStyle(.bordered)
            } else {
                ProgressView("Starting transfer…")
                    .progressViewStyle(.circular)
            }

            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Button("Cancel") {
                viewModel.cancelTransfer()
                viewModel.step = .result
            }
            .buttonStyle(.bordered)
        }
        .task {
            viewModel.startTransfer()
        }
    }
}

private struct TransferItemRow: View {

    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            phaseIcon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.app.displayName)
                    .font(.callout)
                Text(item.app.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.phase == .extracting || item.phase == .installing || item.phase == .archiving {
                ProgressView()
                    .controlSize(.small)
            }
            Text(item.phase.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phaseIcon: some View {
        switch item.phase {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .extracting, .archiving, .installing:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

// MARK: - Step 7: Result

private struct ResultStepView: View {

    let viewModel: iTransferViewModel
    let onDismiss: () -> Void
    let onShowArchive: () -> Void

    private var archiveDir: URL {
        viewModel.archiveDir ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Spacie/Archives", isDirectory: true)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if let result = viewModel.transferResult {
                let allOK = result.failureCount == 0
                Image(systemName: allOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(allOK ? .green : .orange)

                Text(allOK ? "Transfer Complete" : "Transfer Finished with Errors")
                    .font(.title2.weight(.semibold))

                Text("\(result.successCount) succeeded · \(result.failureCount) failed")
                    .foregroundStyle(.secondary)

                if !result.items.isEmpty {
                    List(result.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.app.displayName).font(.callout)
                                if let error = item.error {
                                    Text(error.localizedDescription)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(maxHeight: 180)
                }

                // Show where files were saved
                if result.successCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(archiveDir.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show") {
                            NSWorkspace.shared.open(archiveDir)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 440)
                }

            } else if let error = viewModel.lastError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.red)
                Text("Transfer Failed")
                    .font(.title2.weight(.semibold))
                Text(error)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button("Transfer More") {
                    viewModel.reset()
                }
                .buttonStyle(.bordered)
                Button {
                    onShowArchive()
                } label: {
                    Label("View Archive", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - TransferPhase Label

private extension TransferPhase {
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
