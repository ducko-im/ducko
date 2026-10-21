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
    /// A registration whose server asked for more than the username, password and email, holding its connection open.
    @State private var pendingRegistration: PendingRegistration?
    /// The server's form for `pendingRegistration`, as the user fills it in.
    @State private var serverForm: RegistrationFormInfo?

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
                        if let serverForm {
                            serverFormFields(serverFormBinding(showing: serverForm))
                        } else {
                            registerFields
                        }
                    }
                }

                if mode != .importAdium {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .accessibilityIdentifier("setup-error")
                    }

                    HStack {
                        if serverForm != nil {
                            Button("Cancel") {
                                cancelPendingRegistration()
                            }
                            .accessibilityIdentifier("register-cancel-button")
                        }

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
        .onChange(of: mode) { cancelPendingRegistration() }
        .onDisappear { cancelPendingRegistration() }
    }

    /// Stable height reserved for the mode-dependent content below the picker.
    /// Sized to comfortably fit the tallest fixed layout (Register: four fields
    /// plus the action button and an error line) so toggling between modes does
    /// not move anything above it. The server's registration form fills the
    /// same space and whatever a taller window adds, and scrolls within it.
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

    /// The server's fields, filled in with what was typed before.
    private func serverFormFields(_ form: Binding<RegistrationFormInfo>) -> some View {
        Form {
            RegistrationFormFields(form: form)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("register-server-form")
    }

    /// Binds the server's form, falling back to `shown` once the registration has ended. The fields can still write
    /// while they leave the window, so force-unwrapping `serverForm` would crash. Edits made then are dropped.
    private func serverFormBinding(showing shown: RegistrationFormInfo) -> Binding<RegistrationFormInfo> {
        Binding {
            serverForm ?? shown
        } set: { form in
            if serverForm != nil { serverForm = form }
        }
    }

    // MARK: - Computed

    private var subtitleText: String {
        switch mode {
        case .importAdium:
            "Import your accounts and chat history from Adium."
        case .login, .register:
            serverForm == nil
                ? "Enter your XMPP account details to get started."
                : "The server asks for a few more details."
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
            if let serverForm { return !serverForm.canSubmit }
            return serverDomain.isEmpty || username.isEmpty || password.isEmpty
        }
    }

    // MARK: - Actions

    private func connectAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            _ = try await environment.accountService.createAndConnect(jidString: jidString, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func registerAccount() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        if let pendingRegistration, let serverForm {
            await submit(serverForm, to: pendingRegistration)
            return
        }
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
                pendingRegistration = pending
                serverForm = pending.form
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whether it succeeds or fails, the registration's connection is closed, so a failure returns to the server,
    /// username, password and email fields.
    private func submit(_ form: RegistrationFormInfo, to pending: PendingRegistration) async {
        do {
            _ = try await pending.submit(form)
        } catch {
            errorMessage = error.localizedDescription
        }
        cancelPendingRegistration()
    }

    private func cancelPendingRegistration() {
        guard let pendingRegistration else { return }
        self.pendingRegistration = nil
        serverForm = nil
        Task { await pendingRegistration.cancel() }
    }
}
