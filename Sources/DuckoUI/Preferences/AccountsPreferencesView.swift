import DuckoCore
import SwiftUI

struct AccountsPreferencesView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedAccountID: UUID?
    @State private var editingAccount: Account?
    @State private var isShowingAddSheet = false
    @State private var isDeleteConfirmPresented = false

    private var accounts: [Account] {
        environment.accountService.accounts
    }

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 220)

            accountDetail
                .frame(maxWidth: .infinity)
        }
        .frame(height: 460)
        .task {
            try? await environment.accountService.loadAccounts()
        }
        .sheet(item: $editingAccount) { account in
            AccountEditSheet(account: account)
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AccountAddSheet()
        }
        .confirmationDialog("Remove Account?", isPresented: $isDeleteConfirmPresented) {
            Button("Remove Account Only") {
                deleteSelectedAccount(includeHistory: false)
            }
            Button("Remove Account and Delete Chat History", role: .destructive) {
                deleteSelectedAccount(includeHistory: true)
            }
        } message: {
            Text("Do you also want to delete all chat history for this account? This cannot be undone.")
        }
    }

    // MARK: - Account List

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(accounts, selection: $selectedAccountID) { account in
                HStack {
                    connectionIndicator(for: account.id)
                    Text(account.displayName ?? account.jid.description)
                        .singleLine()
                    if environment.accountService.outageInfos[account.id] != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                            .help("Service outage reported")
                    }
                }
            }
            .listStyle(.bordered)

            HStack(spacing: 0) {
                Button {
                    isShowingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add Account")

                Button {
                    guard selectedAccountID != nil else { return }
                    isDeleteConfirmPresented = true
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selectedAccountID == nil)
                .accessibilityLabel("Remove Account")

                Spacer()
            }
            .padding(.top, 6)
        }
        .padding([.leading, .vertical])
    }

    // MARK: - Account Detail

    @ViewBuilder
    private var accountDetail: some View {
        if let account = accounts.first(where: { $0.id == selectedAccountID }) {
            AccountDetailView(
                account: account,
                onEdit: { editingAccount = account }
            )
        } else {
            Text("Select an account")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func deleteSelectedAccount(includeHistory: Bool) {
        guard let id = selectedAccountID else { return }
        Task {
            await environment.removeAccount(id, includeHistory: includeHistory)
            selectedAccountID = nil
        }
    }

    private func connectionIndicator(for accountID: UUID) -> some View {
        let state = environment.accountService.connectionStates[accountID]
        let color: Color = switch state {
        case .connected:
            .green
        case .connecting:
            .yellow
        case .error:
            .red
        case .disconnected, .none:
            .gray
        }
        return Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(stateLabel(state))
    }

    private func stateLabel(_ state: AccountService.ConnectionState?) -> String {
        switch state {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .error: "Error"
        case .disconnected, .none: "Disconnected"
        }
    }
}

// MARK: - Account Detail View

private struct AccountDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingConnectionInfo = false
    @State private var isShowingServerInfo = false
    @State private var isShowingChangePassword = false
    @State private var isShowingRegistrationForm = false
    @State private var isCancelAccountConfirmPresented = false
    @State private var cancelAccountError: String?
    let account: Account
    let onEdit: () -> Void

    private var connectionState: AccountService.ConnectionState? {
        environment.accountService.connectionStates[account.id]
    }

    private var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private var isError: Bool {
        if case .error = connectionState { return true }
        return false
    }

    var body: some View {
        Form {
            Section("Account") {
                LabeledContent("JID", value: account.jid.description)

                if let displayName = account.displayName {
                    LabeledContent("Display Name", value: displayName)
                }

                if let host = account.host {
                    LabeledContent("Host", value: host)
                }

                if let port = account.port {
                    LabeledContent("Port", value: "\(port)")
                }

                if let resource = account.resource {
                    LabeledContent("Resource", value: resource)
                }
            }

            Section("Status") {
                LabeledContent("Enabled", value: account.isEnabled ? "Yes" : "No")
                LabeledContent("Connect on Launch", value: account.connectOnLaunch ? "Yes" : "No")
                LabeledContent("Require TLS", value: account.requireTLS ? "Yes" : "No")
                LabeledContent("Connection") {
                    Text(connectionLabel)
                        .foregroundStyle(isError ? Color.red : .secondary)
                }
            }

            Section {
                HStack {
                    Button("Edit…") {
                        onEdit()
                    }

                    if isConnected {
                        actionsMenu
                    }

                    Spacer()

                    connectionButton
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingConnectionInfo) {
            if let info = environment.accountService.tlsInfo(for: account.id) {
                ConnectionInfoView(tlsInfo: info)
            }
        }
        .onChange(of: environment.accountService.tlsInfo(for: account.id) == nil) { _, unavailable in
            if unavailable { isShowingConnectionInfo = false }
        }
        .sheet(isPresented: $isShowingServerInfo) {
            ServerInfoView(accountID: account.id)
        }
        .sheet(isPresented: $isShowingChangePassword) {
            ChangePasswordSheet(accountID: account.id)
        }
        .sheet(isPresented: $isShowingRegistrationForm) {
            RegistrationFormSheet(accountID: account.id)
        }
        .confirmationDialog("Unregister Account?", isPresented: $isCancelAccountConfirmPresented) {
            Button("Unregister Account Only") {
                cancelAccount(includeHistory: false)
            }
            Button("Unregister Account and Delete Chat History", role: .destructive) {
                cancelAccount(includeHistory: true)
            }
        } message: {
            Text("This will permanently unregister your account from the server and remove it locally. You can also choose to delete all chat history. This action cannot be undone.")
        }
        .alert("Account Unregistration Failed", isPresented: Binding(
            get: { cancelAccountError != nil },
            set: { if !$0 { cancelAccountError = nil } }
        )) {
            Button("OK") { cancelAccountError = nil }
        } message: {
            if let cancelAccountError {
                Text(cancelAccountError)
            }
        }
    }

    private var actionsMenu: some View {
        Menu("Actions") {
            if environment.accountService.tlsInfo(for: account.id) != nil {
                Button("Connection Info…") {
                    isShowingConnectionInfo = true
                }
            }

            Button("Server Info…") {
                isShowingServerInfo = true
            }

            Divider()

            Button("Change Password…") {
                isShowingChangePassword = true
            }

            Button("Check Registration…") {
                isShowingRegistrationForm = true
            }

            Divider()

            Button("Unregister Account…", role: .destructive) {
                isCancelAccountConfirmPresented = true
            }
        }
        .fixedSize()
        .accessibilityIdentifier("account-actions-menu")
    }

    private var connectionLabel: String {
        switch connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case let .error(message): message
        case .disconnected, .none: "Disconnected"
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch connectionState {
        case .connected, .connecting:
            Button("Disconnect") {
                Task {
                    await environment.accountService.disconnect(accountID: account.id)
                }
            }
        case .disconnected, .error, .none:
            Button("Connect") {
                Task {
                    try? await environment.accountService.connect(accountID: account.id)
                }
            }
        }
    }

    private func cancelAccount(includeHistory: Bool) {
        Task {
            do {
                try await environment.cancelAccount(account.id, includeHistory: includeHistory)
            } catch {
                cancelAccountError = error.localizedDescription
            }
        }
    }
}

// MARK: - Account Edit Sheet

private struct AccountEditSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String
    @State private var host: String
    @State private var portString: String
    @State private var resource: String
    @State private var connectOnLaunch: Bool
    @State private var isEnabled: Bool
    @State private var requireTLS: Bool

    private let accountID: UUID

    init(account: Account) {
        self.accountID = account.id
        _displayName = State(initialValue: account.displayName ?? "")
        _host = State(initialValue: account.host ?? "")
        _portString = State(initialValue: account.port.map(String.init) ?? "")
        _resource = State(initialValue: account.resource ?? "")
        _connectOnLaunch = State(initialValue: account.connectOnLaunch)
        _isEnabled = State(initialValue: account.isEnabled)
        _requireTLS = State(initialValue: account.requireTLS)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Display Name", text: $displayName)
                TextField("Host (optional)", text: $host)
                TextField("Port (optional)", text: $portString)
                TextField("Resource (optional)", text: $resource)
                Toggle("Connect on Launch", isOn: $connectOnLaunch)
                Toggle("Require TLS", isOn: $requireTLS)
                    .accessibilityIdentifier("requireTLSToggle")
                Toggle("Enabled", isOn: $isEnabled)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func save() {
        guard var account = environment.accountService.accounts.first(where: { $0.id == accountID }) else { return }
        account.displayName = displayName.isEmpty ? nil : displayName
        account.host = host.isEmpty ? nil : host
        account.port = Int(portString)
        account.resource = resource.isEmpty ? nil : resource
        account.connectOnLaunch = connectOnLaunch
        account.requireTLS = requireTLS
        account.isEnabled = isEnabled
        Task {
            try? await environment.accountService.updateAccount(account)
            dismiss()
        }
    }
}

// MARK: - Account Add Sheet

private struct AccountAddSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var jid = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("JID (e.g. alice@example.com)", text: $jid)
                    .textContentType(.username)
                SecureField("Password", text: $password)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    addAccount()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(jid.isEmpty || password.isEmpty || isAdding)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func addAccount() {
        errorMessage = nil
        isAdding = true
        Task {
            do {
                // `createAndConnect` already connects, persists the password, and reloads
                // accounts; leaving it connected lets the new account's roster appear
                // without a relaunch.
                _ = try await environment.accountService.createAndConnect(jidString: jid, password: password)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}

// MARK: - Change Password Sheet

private struct ChangePasswordSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let accountID: UUID
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isChanging = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                SecureField("New Password", text: $newPassword)
                    .accessibilityIdentifier("new-password-field")
                SecureField("Confirm Password", text: $confirmPassword)
                    .accessibilityIdentifier("confirm-password-field")

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Change Password") {
                    changePassword()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newPassword.isEmpty || newPassword != confirmPassword || isChanging)
            }
            .padding()
        }
        .frame(width: 400)
    }

    private func changePassword() {
        errorMessage = nil
        isChanging = true
        Task {
            do {
                try await environment.accountService.changePassword(accountID: accountID, newPassword: newPassword)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isChanging = false
            }
        }
    }
}
