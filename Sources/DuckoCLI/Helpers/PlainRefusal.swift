import DuckoCore
import Foundation

/// Where a sign-in was refused because the server offered only PLAIN, which decides how the user can allow it.
enum PlainRefusalContext {
    /// A stored account, which keeps the refusal until `account set` allows PLAIN.
    case storedAccount
    /// `account add` with its `--host` and `--port`, which rolled the new account back.
    case accountAdd(host: String?, port: UInt16?)
}

/// The line that follows a refusal, naming the command that lets the account send its password to that server.
func plainRefusalHint(_ context: PlainRefusalContext, jid: String) -> String {
    switch context {
    case .storedAccount:
        "Run 'ducko account set \(jid) --allow-plain' to send the password to this server."
    case let .accountAdd(host, port):
        "Run 'ducko account add \(jid)\(host.map { " --host \($0)" } ?? "")\(port.map { " --port \($0)" } ?? "") --allow-plain' "
            + "to add the account and send the password to this server."
    }
}

/// Connects a stored account. A refusal to send the password to a server offering only PLAIN prints the hint on
/// standard error before it is rethrown.
@MainActor
func connectStored(_ environment: AppEnvironment, accountID: UUID, password: String? = nil) async throws {
    do {
        if let password {
            try await environment.accountService.connect(accountID: accountID, password: password)
        } else {
            try await environment.accountService.connect(accountID: accountID)
        }
    } catch {
        if AccountService.isPLAINRefusal(error),
           let jid = environment.accountService.accounts.first(where: { $0.id == accountID })?.jid.description {
            printToStandardError(plainRefusalHint(.storedAccount, jid: jid))
        }
        throw error
    }
}
