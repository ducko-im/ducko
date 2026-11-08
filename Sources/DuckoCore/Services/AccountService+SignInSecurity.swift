import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.account")

public extension AccountService {
    /// A connect attempt refused because the server offered only PLAIN to an account that does not allow it.
    struct SignInSecurityWarning: Sendable {
        public let accountJID: String
    }

    /// Sets whether a server that offers only PLAIN gets the account's password. Allowing it hides the warning. The next
    /// sign-in with a verified SCRAM success turns it off again.
    func setAllowsPLAIN(_ allowed: Bool, for accountID: UUID) async throws {
        try await store.setAllowsPLAIN(allowed, accountID: accountID)
        if allowed {
            signInSecurityWarnings[accountID] = nil
        }
        try await loadAccounts()
    }

    /// Saves an edit of `account` whose PLAIN permission read `openedAllowsPLAIN` when the edit began. The permission is
    /// written only when the edit changed it, since Ducko turns it off on its own after a verified SCRAM sign-in, and the
    /// edit must not undo that.
    func updateAccount(_ account: Account, allowsPLAIN: Bool, openedWith openedAllowsPLAIN: Bool) async throws {
        try await updateAccount(account)
        if allowsPLAIN != openedAllowsPLAIN {
            try await setAllowsPLAIN(allowsPLAIN, for: account.id)
        }
    }

    /// Hides the warning and keeps refusing. The next refused attempt publishes it again.
    func dismissSignInSecurityWarning(for accountID: UUID) {
        signInSecurityWarnings[accountID] = nil
    }

    /// Whether the sign-in was refused because the server offered only PLAIN to an account that does not allow it.
    nonisolated static func isPLAINRefusal(_ error: any Error) -> Bool {
        guard case .plainSignInRefused = error as? XMPPClientError else { return false }
        return true
    }

    /// An account in its first sign-in from `createAndConnect` gets no warning: the account is rolled back when that
    /// sign-in fails, so the form that added it reports the refusal.
    internal func publishSignInSecurityWarning(accountID: UUID) {
        guard !accountsInFirstSignIn.contains(accountID),
              let account = accounts.first(where: { $0.id == accountID }) else { return }
        signInSecurityWarnings[accountID] = SignInSecurityWarning(accountJID: account.jid.description)
    }

    /// Runs `connect`, then forbids PLAIN when `client` verified a SCRAM success, even if `connect` threw. The server
    /// proved it knows the password before the steps that can still fail, such as resource binding.
    internal func signIn(with client: XMPPClient, accountID: UUID, _ connect: () async throws -> Void) async throws {
        do {
            try await connect()
        } catch {
            await forbidPLAINIfVerified(by: client, accountID: accountID)
            throw error
        }
        await forbidPLAINIfVerified(by: client, accountID: accountID)
    }

    private func forbidPLAINIfVerified(by client: XMPPClient, accountID: UUID) async {
        guard let mechanism = client.verifiedSCRAMMechanism else { return }
        await forbidPLAIN(for: accountID, verifiedWith: mechanism)
    }

    /// Stops the account from sending its password to a server offering only PLAIN, after a sign-in verified
    /// `mechanism`. It writes even when the account already refuses, since the user may have allowed PLAIN while that
    /// sign-in was under way.
    internal func forbidPLAIN(for accountID: UUID, verifiedWith mechanism: String) async {
        do {
            try await store.setAllowsPLAIN(false, accountID: accountID)
            log.info("Signed in with \(mechanism), so a sign-in offering only PLAIN is refused from now on")
            try await loadAccounts()
        } catch {
            log.error("Could not record that the account no longer sends its password to a server offering only PLAIN: \(error)")
        }
    }
}
