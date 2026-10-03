import AppKit
import DuckoCore
import SwiftUI

struct AdiumImportCache {
    let accounts: [AdiumAccount]
    let logSources: [AdiumServiceAccount]
    let keychainPasswords: [String: String]
}

struct AdiumOnboardingImportView: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var importInProgress: Bool
    @Binding var cache: AdiumImportCache?

    @State private var step: ImportStep = .loading
    @State private var selectedAccountIDs: Set<String> = []
    @State private var passwords: [String: String] = [:]
    @State private var progress: AdiumImportService.ImportProgress?
    @State private var accountResults: [AccountResult] = []
    @State private var importResult: AdiumImportService.ImportProgress?
    @State private var logImportSkipped = false
    @State private var succeededAccountIDs: Set<String> = []
    @State private var authErrorMessages: [String: String] = [:]
    @State private var totalSelectedAccountCount = 0

    private enum ImportStep {
        case loading
        case accountSetup
        case importing
        case complete
    }

    private typealias AccountResult = AdiumImportCompletionView.AccountResult

    var body: some View {
        VStack(spacing: 12) {
            switch step {
            case .loading:
                loadingView
            case .accountSetup:
                accountSetupView
            case .importing:
                importingView
            case .complete:
                completionView
            }
        }
        .frame(maxWidth: 300)
        .task {
            await discover()
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Looking for Adium data…")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }

    private var accountSetupView: some View {
        VStack(spacing: 12) {
            if accounts.isEmpty, logSources.isEmpty {
                noDataView
            } else {
                if !accounts.isEmpty {
                    accountListView
                }

                let totalFiles = logSources.reduce(0) { $0 + $1.fileCount }
                if totalFiles > 0 {
                    Text("\(logSources.count) account(s), \(totalFiles) log file(s) to import")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await performImport() }
                } label: {
                    Text("Import from Adium")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasImportableData)
                .accessibilityIdentifier("import-button")
            }
        }
    }

    private var noDataView: some View {
        VStack(spacing: 12) {
            Text("No Adium installation found.")
                .foregroundStyle(.secondary)

            Button("Choose Adium Folder…") {
                browseForAdiumFolder()
            }
            .accessibilityIdentifier("choose-adium-folder-button")

            Text("You can also switch to Login or Register above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var accountListView: some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                let alreadySucceeded = succeededAccountIDs.contains(account.id)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(
                        get: { selectedAccountIDs.contains(account.id) },
                        set: { selected in
                            if selected {
                                selectedAccountIDs.insert(account.id)
                            } else {
                                selectedAccountIDs.remove(account.id)
                            }
                        }
                    )) {
                        Text(account.uid)
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(alreadySucceeded)
                    .accessibilityIdentifier("account-toggle-\(account.id)")

                    if alreadySucceeded {
                        Label("Connected", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if selectedAccountIDs.contains(account.id) {
                        if keychainPasswords[account.id] != nil, authErrorMessages[account.id] == nil {
                            Label("Password from Keychain", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            SecureField("Password", text: Binding(
                                get: { passwords[account.id, default: ""] },
                                set: { passwords[account.id] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.password)
                            .accessibilityIdentifier("account-password-\(account.id)")
                        }

                        if let authError = authErrorMessages[account.id] {
                            Text(authError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let server = account.connectServer {
                            Text("Server: \(server)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var importingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)

            if totalSelectedAccountCount > 0 {
                let succeeded = accountResults.filter(\.success).count
                Text("\(succeeded)/\(totalSelectedAccountCount) accounts connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress {
                AdiumImportProgressView(progress: progress)
            }
        }
    }

    private var completionView: some View {
        VStack(spacing: 12) {
            AdiumImportCompletionView(result: importResult, accountResults: accountResults)

            if logImportSkipped {
                Text("Log import was skipped because no accounts could connect. You can import logs separately from the app menu.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Done") {
                importInProgress = false
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("import-done-button")
        }
    }

    // MARK: - Computed

    private var selectedAccountsWithPasswords: [AdiumAccount] {
        accounts.filter { account in
            selectedAccountIDs.contains(account.id)
                && !succeededAccountIDs.contains(account.id)
                && !(passwords[account.id]?.isEmpty ?? true)
        }
    }

    private var hasImportableData: Bool {
        let pendingSelectedIDs = selectedAccountIDs.subtracting(succeededAccountIDs)
        if !pendingSelectedIDs.isEmpty {
            return pendingSelectedIDs.allSatisfy { id in
                !(passwords[id]?.isEmpty ?? true)
            }
        }
        return !logSources.isEmpty || !succeededAccountIDs.isEmpty
    }

    private var accounts: [AdiumAccount] {
        cache?.accounts ?? []
    }

    private var logSources: [AdiumServiceAccount] {
        cache?.logSources ?? []
    }

    private var keychainPasswords: [String: String] {
        cache?.keychainPasswords ?? [:]
    }

    // MARK: - Actions

    private func discover() async {
        if let cache {
            prefill(cache.keychainPasswords)
        } else {
            discoverAt(AdiumAccountDiscovery.defaultUserURL)
        }
        step = .accountSetup
    }

    private func browseForAdiumFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = AdiumAccountDiscovery.defaultUserURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        discoverAt(url)
    }

    private func discoverAt(_ userDirectoryURL: URL) {
        let accounts = AdiumAccountDiscovery.discoverAccounts(at: userDirectoryURL)

        var keychainPasswords: [String: String] = [:]
        for account in accounts {
            if let pw = AdiumKeychainReader.password(for: account) {
                keychainPasswords[account.id] = pw
            }
        }

        let logsURL = userDirectoryURL.appendingPathComponent("Logs")
        let logSources = (try? AdiumLogDiscovery.discoverSources(at: logsURL)) ?? []

        cache = AdiumImportCache(accounts: accounts, logSources: logSources, keychainPasswords: keychainPasswords)
        prefill(keychainPasswords)
    }

    /// Fills in and selects every account whose password Adium's keychain supplied.
    private func prefill(_ keychainPasswords: [String: String]) {
        for (id, pw) in keychainPasswords {
            passwords[id] = pw
        }
        selectedAccountIDs = Set(keychainPasswords.keys)
    }

    private func performImport() async {
        importInProgress = true
        step = .importing
        authErrorMessages = [:]
        totalSelectedAccountCount = selectedAccountIDs.count
        accountResults = accounts.filter { succeededAccountIDs.contains($0.id) }
            .map { AccountResult(id: $0.id, jid: $0.uid, success: true, error: nil) }

        // Phase 1: Create and connect accounts (skip already-succeeded ones)
        for account in selectedAccountsWithPasswords {
            let password = passwords[account.id] ?? ""
            do {
                _ = try await environment.accountService.createAndConnect(
                    jidString: account.uid,
                    password: password,
                    host: account.connectServer,
                    port: account.connectServer != nil ? (account.connectPort ?? 5222) : nil,
                    resource: account.resource,
                    requireTLS: true,
                    connectOnLaunch: account.autoConnect,
                    importedFrom: "Adium"
                )
                succeededAccountIDs.insert(account.id)
                accountResults.append(AccountResult(id: account.id, jid: account.uid, success: true, error: nil))
            } catch {
                if AccountService.isAuthenticationError(error) {
                    authErrorMessages[account.id] = "Authentication failed. Please check your password."
                    passwords[account.id] = ""
                } else {
                    accountResults.append(AccountResult(id: account.id, jid: account.uid, success: false, error: error.localizedDescription))
                }
            }
        }

        // If any auth failures, rewind to account setup for retry
        if !authErrorMessages.isEmpty {
            importInProgress = !succeededAccountIDs.isEmpty
            step = .accountSetup
            return
        }

        await importLogsIfNeeded()
        step = .complete
    }

    private func importLogsIfNeeded() async {
        let accountsWereSelected = !selectedAccountIDs.isEmpty
        let anyAccountSucceeded = accountResults.contains(where: \.success)
        let shouldImportLogs = !logSources.isEmpty && (!accountsWereSelected || anyAccountSucceeded)

        if shouldImportLogs {
            let importService = AdiumImportService(store: environment.store, transcripts: environment.transcripts)
            do {
                importResult = try await importService.importLogs(from: logSources) { p in
                    Task { @MainActor in
                        progress = p
                    }
                }
            } catch {
                importResult = .failure(error: error)
            }
        } else if accountsWereSelected, !logSources.isEmpty {
            logImportSkipped = true
        }
    }
}
