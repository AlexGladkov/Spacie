import SwiftUI

// Step 1: dependency check + Apple ID login.

// MARK: - Step 1: Dependency Check

struct DependencyCheckStepView: View {

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
                    viewModel.cancelAppleIDLogin()
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
