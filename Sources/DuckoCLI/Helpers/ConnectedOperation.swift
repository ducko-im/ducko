import DuckoCore
import DuckoXMPP
import Foundation

@MainActor
enum ConnectedOperation {
    struct Preparation {
        let environment: AppEnvironment
        let account: DuckoCore.Account
        let password: String
    }

    /// Bootstraps the environment and resolves the selected account and its password without connecting.
    static func prepare(formatter: any CLIFormatter, account: String?, isInteractive: Bool = false) async throws -> Preparation {
        let environment = try CLIBootstrap.setUp(formatter: formatter, isInteractive: isInteractive).environment
        let selectedAccount = try await resolveAccount(account, environment: environment)
        guard let password = try CredentialHelper.getPassword(for: selectedAccount.jid.description, using: environment.credentialStore) else {
            throw CLIError.noPassword
        }
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
        password: String,
        operation: @MainActor () async throws -> Result
    ) async throws -> Result {
        try await run(
            connect: { try await environment.accountService.connect(accountID: account.id, password: password) },
            ready: { try await waitForConnected(accountID: account.id, environment: environment) },
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
