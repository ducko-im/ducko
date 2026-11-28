import DuckoCore
import DuckoXMPP
import Foundation

@MainActor
enum ConnectedOperation {
    struct Preparation {
        let environment: AppEnvironment
        let account: DuckoCore.Account
        /// Nil for an account that signs in through the browser.
        let password: String?
    }

    /// Bootstraps the environment and resolves the selected account and its password without connecting.
    static func prepare(formatter: any CLIFormatter, account: String?, isInteractive: Bool = false) async throws -> Preparation {
        let environment = try CLIBootstrap.setUp(formatter: formatter, isInteractive: isInteractive).environment
        let selectedAccount = try await resolveAccount(account, environment: environment)
        let password = try CredentialHelper.storedSignInPassword(for: selectedAccount, using: environment.credentialStore)
        return Preparation(environment: environment, account: selectedAccount, password: password)
    }

    static func run<Result: Sendable>(
        formatter: any CLIFormatter,
        account: String?,
        operation: @MainActor (AppEnvironment, DuckoCore.Account) async throws -> Result
    ) async throws -> Result {
        let prepared = try await prepare(formatter: formatter, account: account)
        return try await run(environment: prepared.environment, account: prepared.account, password: prepared.password) {
            try await operation(prepared.environment, prepared.account)
        }
    }

    static func run<Result: Sendable>(
        environment: AppEnvironment,
        account: DuckoCore.Account,
        password: String?,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        try await run(
            connect: { try await connectStored(environment, accountID: account.id, password: password) },
            ready: { try await waitForSetUp(accountID: account.id, environment: environment) },
            operation: operation,
            teardown: { await environment.accountService.disconnect(accountID: account.id) }
        )
    }

    static func run<Result: Sendable>(
        connect: @MainActor () async throws -> Void,
        ready: @MainActor () async throws -> Void,
        operation: @MainActor () async throws -> Result,
        teardown: @MainActor () async -> Void
    ) async throws -> Result {
        do {
            try Task.checkCancellation()
            try await connect()
            try Task.checkCancellation()
            try await ready()
            try Task.checkCancellation()
            let result = try await operation()
            await teardown()
            return result
        } catch {
            await teardown()
            throw error
        }
    }
}

func waitForConnected(accountID: UUID, environment: AppEnvironment) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while ContinuousClock.now < deadline {
        let state = await MainActor.run { environment.accountService.connectionStates[accountID] }
        switch state {
        case .connected:
            return
        case let .error(message):
            throw CLIError.connectionFailed(message)
        case .disconnected, .connecting, .none:
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    throw CLIError.connectionTimeout
}

/// Waits for the account to connect, then for its first encryption setup attempt, so a one-shot command runs with
/// whatever identity that attempt installed and never exits while its new keys are being stored or published.
func waitForSetUp(accountID: UUID, environment: AppEnvironment) async throws {
    try await waitForConnected(accountID: accountID, environment: environment)
    await environment.omemoService.awaitSetupAttempt(accountID: accountID)
}

func resolveAccount(_ accountIDString: String?, environment: AppEnvironment) async throws -> DuckoCore.Account {
    try await environment.accountService.loadAccounts()
    let accounts = await MainActor.run { environment.accountService.accounts }
    guard !accounts.isEmpty else {
        throw CLIError.noAccounts
    }

    if let accountIDString {
        guard let uuid = UUID(uuidString: accountIDString),
              let found = accounts.first(where: { $0.id == uuid })
        else {
            throw CLIError.accountNotFound(accountIDString)
        }
        return found
    }
    return accounts[0]
}

func resolveAccount(byJID jid: String, environment: AppEnvironment) async throws -> DuckoCore.Account {
    guard let bareJID = BareJID.parse(jid) else {
        throw CLIError.invalidJID(jid)
    }
    try await environment.accountService.loadAccounts()
    let accounts = await MainActor.run { environment.accountService.accounts }
    guard let account = accounts.first(where: { $0.jid == bareJID }) else {
        throw CLIError.accountNotFound(jid)
    }
    return account
}

/// Connects a stored account, printing `signInFailureHints` on standard error before a failure is rethrown. Without
/// `password`, it connects with what is stored for the account: its password or its browser grant.
@MainActor
func connectStored(_ environment: AppEnvironment, accountID: UUID, password: String? = nil) async throws {
    do {
        if let password {
            try await environment.accountService.connect(accountID: accountID, password: password)
        } else {
            try await environment.accountService.connect(accountID: accountID)
        }
    } catch {
        if let jid = environment.accountService.accounts.first(where: { $0.id == accountID })?.jid.description {
            let needed = environment.accountService.browserSignInNeeded.contains(accountID)
            for hint in signInFailureHints(for: error, .storedAccount, jid: jid, browserSignInNeeded: needed) {
                printToStandardError(hint)
            }
        }
        throw error
    }
}

/// Connects a stored account for a command that keeps its session, then waits until it is connected. From the first
/// connect on, a grant that needs a new sign-in prints `browserSignInAgainHint`; a failed first connect prints its hints
/// through `connectStored` instead.
@MainActor
func connectHeldSession(_ environment: AppEnvironment, account: DuckoCore.Account, password: String?) async throws {
    try await connectStored(environment, accountID: account.id, password: password)
    // Installed before anything else runs, so a refusal published while the session sets up prints too.
    installBrowserSignInNeededHint(on: environment.accountService, jid: account.jid.description)
    try await waitForConnected(accountID: account.id, environment: environment)
}
