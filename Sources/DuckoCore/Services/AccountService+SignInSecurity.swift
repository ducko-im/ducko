import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.account")

public extension AccountService {
    /// A connect attempt refused because the server offered only PLAIN to an account that has signed in with SCRAM.
    struct SignInSecurityWarning: Sendable {
        public let accountJID: String
    }

    /// Clears the account's SCRAM requirement, so a server that offers only PLAIN gets the password again. The next
    /// sign-in with a verified SCRAM success sets it again.
    func resetSignInSecurity(for accountID: UUID) async throws {
        try await store.setRequiresSCRAM(false, accountID: accountID)
        signInSecurityWarnings[accountID] = nil
        try await loadAccounts()
    }

    /// Hides the warning and leaves the requirement in place. The next refused attempt publishes it again.
    func dismissSignInSecurityWarning(for accountID: UUID) {
        signInSecurityWarnings[accountID] = nil
    }

    internal func publishSignInSecurityWarning(accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        signInSecurityWarnings[accountID] = SignInSecurityWarning(accountJID: account.jid.description)
    }

    /// Runs `connect`, then requires SCRAM from then on when `client` verified a SCRAM success, even if `connect`
    /// threw. The server proved it knows the password before the steps that can still fail, such as resource binding.
    internal func signIn(with client: XMPPClient, account: Account, _ connect: () async throws -> Void) async throws {
        do {
            try await connect()
        } catch {
            await requireSCRAMIfVerified(by: client, account: account)
            throw error
        }
        await requireSCRAMIfVerified(by: client, account: account)
    }

    private func requireSCRAMIfVerified(by client: XMPPClient, account: Account) async {
        guard let mechanism = client.verifiedSCRAMMechanism else { return }
        await requireSCRAM(for: account, verifiedWith: mechanism)
    }

    /// Records that `account` requires SCRAM from now on, after a sign-in verified `mechanism`.
    internal func requireSCRAM(for account: Account, verifiedWith mechanism: String) async {
        guard !account.requiresSCRAM else { return }
        do {
            try await store.setRequiresSCRAM(true, accountID: account.id)
            log.info("Signed in with \(mechanism), so a sign-in offering only PLAIN is refused from now on")
            try await loadAccounts()
        } catch {
            log.error("Could not record that the account requires SCRAM: \(error)")
        }
    }
}
