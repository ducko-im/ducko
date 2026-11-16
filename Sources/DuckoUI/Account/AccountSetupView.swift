import AppKit
import DuckoCore
import SwiftUI

struct AccountSetupView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var importInProgress: Bool
    @State private var mode: SetupMode = .importAdium
    @State private var jidString = ""
    @State private var password = ""
    @State private var serverDomain = ""
    @State private var username = ""
    @State private var email = ""
    @State private var adiumImportCache: AdiumImportCache?
    @State private var isConnecting = false
    @State private var errorMessage: String?
    /// Whether the login's first sign-in was refused because the server offers only PLAIN.
    @State private var isPLAINRefused = false
    /// A registration whose server asked for more than the username, password and email, shown in a sheet while it
    /// holds its connection open.
    @State private var pendingRegistration: PendingRegistrationSheet.Item?

    private enum SetupMode: String, CaseIterable {
        case importAdium = "Import"
        case login = "Login"
        case register = "Register"
    }

    var body: some View {
        VStack(spacing: 20) {
            if let iconImage = NSApplication.shared.applicationIconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 128, height: 128)
            }

            Text("Welcome to Ducko")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(subtitleText)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $mode) {
                ForEach(SetupMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(importInProgress)
            .frame(maxWidth: 300)
            .accessibilityIdentifier("setup-mode-picker")

            // Reserve a stable footprint for the mode-dependent area and pin its
            // content to the top, so the icon, title, subtitle, and segmented
            // control above never shift when switching modes or when the error
            // message appears.
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    switch mode {
                    case .importAdium:
                        AdiumOnboardingImportView(
                            importInProgress: $importInProgress,
                            cache: $adiumImportCache
                        )
                    case .login:
                        loginFields
                    case .register:
                        registerFields
                    }
                }

                if mode != .importAdium {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .accessibilityIdentifier("setup-error")
                    }

                    if mode == .login, isPLAINRefused, !isConnecting {
                        PlainRefusalRetry {
                            Task { await connectAccount(allowsPLAIN: true) }
                        }
                    }

                    HStack {
                        Button {
                            Task {
                                switch mode {
                                case .login:
                                    await connectAccount()
                                case .register:
                                    await registerAccount()
                                case .importAdium:
                                    break
                                }
                            }
                        } label: {
                            if isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(mode == .login ? "Connect" : "Register")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isActionDisabled)
                        .accessibilityIdentifier(mode == .login ? "connect-button" : "register-button")
                    }
                }
            }
            .frame(maxWidth: 300, minHeight: reservedContentHeight, alignment: .top)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
        .sheet(item: $pendingRegistration) { item in
            PendingRegistrationSheet(pending: item.pending) { failure in
                errorMessage = failure
            }
        }
    }

    /// Stable height reserved for the mode-dependent content below the picker.
    /// Sized to comfortably fit the tallest fixed layout (Register: four fields
    /// plus the action button and an error line) so toggling between modes does
    /// not move anything above it.
    private let reservedContentHeight: CGFloat = 220

    // MARK: - Fields

    @ViewBuilder
    private var loginFields: some View {
        TextField("JID (e.g. alice@example.com)", text: $jidString)
            .textFieldStyle(.roundedBorder)
            .textContentType(.username)
            .accessibilityIdentifier("jid-field")

        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .textContentType(.password)
            .accessibilityIdentifier("password-field")
    }

    @ViewBuilder
    private var registerFields: some View {
        TextField("Server (e.g. example.com)", text: $serverDomain)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("register-server-field")

        TextField("Username", text: $username)
            .textFieldStyle(.roundedBorder)
            .textContentType(.username)
            .accessibilityIdentifier("register-username-field")

        SecureField("Password", text: $password)
            .textFieldStyle(.roundedBorder)
            .textContentType(.newPassword)
            .accessibilityIdentifier("register-password-field")

        TextField("Email (optional)", text: $email)
            .textFieldStyle(.roundedBorder)
            .textContentType(.emailAddress)
            .accessibilityIdentifier("register-email-field")
    }

    // MARK: - Computed

    private var subtitleText: String {
        switch mode {
        case .importAdium:
            "Import your accounts and chat history from Adium."
        case .login, .register:
            "Enter your XMPP account details to get started."
        }
    }

    private var isActionDisabled: Bool {
        if isConnecting { return true }
        switch mode {
        case .importAdium:
            return true
        case .login:
            return jidString.isEmpty || password.isEmpty
        case .register:
            return serverDomain.isEmpty || username.isEmpty || password.isEmpty
        }
    }

    // MARK: - Actions

    private func connectAccount(allowsPLAIN: Bool = false) async {
        isConnecting = true
        errorMessage = nil
        isPLAINRefused = false
        defer { isConnecting = false }

        do {
            _ = try await environment.accountService.createAndConnect(jidString: jidString, password: password, allowsPLAIN: allowsPLAIN)
        } catch {
            errorMessage = error.localizedDescription
            isPLAINRefused = AccountService.isPLAINRefusal(error)
        }
    }

    private func registerAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            let outcome = try await environment.accountService.registerAccount(
                domain: serverDomain,
                username: username,
                password: password,
                email: email.isEmpty ? nil : email
            )
            switch outcome {
            case .registered:
                break
            case let .needsMoreFields(pending):
                pendingRegistration = PendingRegistrationSheet.Item(pending: pending)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
