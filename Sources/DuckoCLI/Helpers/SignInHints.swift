import DuckoCore
import Foundation

/// Which command failed to sign in, which decides the command a hint names.
enum SignInHintContext {
    /// A stored account, which keeps its sign-in settings until a command changes them.
    case storedAccount
    /// `account add` with its `--host` and `--port`, which rolled the new account back.
    case accountAdd(host: String?, port: UInt16?)
}

/// The line that follows a refusal to send the password to a server offering only PLAIN, naming the command that lets
/// the account send it.
func plainRefusalHint(_ context: SignInHintContext, jid: String) -> String {
    switch context {
    case .storedAccount:
        "Run 'ducko account set \(jid) --allow-plain' to send the password to this server."
    case let .accountAdd(host, port):
        "Run 'ducko account add \(jid)\(endpointArguments(host: host, port: port)) --allow-plain' "
            + "to add the account and send the password to this server."
    }
}

/// The line that follows a failed password sign-in where the server offers sign-in through the browser, and a
/// `browser-sign-in` of a password account without `--replace-password`.
func browserSignInHint(_ context: SignInHintContext, jid: String) -> String {
    switch context {
    case .storedAccount:
        "Run 'ducko account browser-sign-in \(jid) --replace-password' to switch this account to browser sign-in."
    case let .accountAdd(host, port):
        "Run 'ducko account add \(jid)\(endpointArguments(host: host, port: port)) --sso' to sign in through the browser."
    }
}

/// The line that follows a browser account's grant the provider no longer accepts, and a `browser-sign-in
/// --replace-password` of an account that already signs in through the browser.
func browserSignInAgainHint(jid: String) -> String {
    "Run 'ducko account browser-sign-in \(jid)' to sign in again."
}

/// The hints for a failed sign-in: a refusal to send the password to a server offering only PLAIN, a server that
/// offers sign-in through the browser, and a browser grant that needs a new sign-in. `browserSignInNeeded` reports that
/// last case when the service settled it without throwing `SSOError.grantInvalid`.
func signInFailureHints(for error: any Error, _ context: SignInHintContext, jid: String, browserSignInNeeded: Bool = false) -> [String] {
    var hints: [String] = []
    if AccountService.isPLAINRefusal(error) {
        hints.append(plainRefusalHint(context, jid: jid))
    }
    if AccountService.isBrowserSignInOffered(error) {
        hints.append(browserSignInHint(context, jid: jid))
    }
    if error as? SSOError == .grantInvalid || browserSignInNeeded {
        hints.append(browserSignInAgainHint(jid: jid))
    }
    return hints
}

/// The hints for a failed `account add --sso` or `account browser-sign-in`: the invocation that matches how the account
/// signs in, or the provider and the redirect addresses an administrator's client must allow when the provider needs
/// one.
func browserSignInFailureHints(for error: any Error, jid: String) -> [String] {
    if case let .clientIDRequired(issuer) = error as? SSOError {
        return ["The sign-in provider \(issuer) needs a client ID that allows these redirect addresses:"]
            + SSORedirect.redirectURIs(forIssuer: issuer).map { "  \($0)" }
            + ["Run the command again with --client-id <id> once the server's administrator has set one up."]
    }
    switch error as? AccountService.AccountServiceError {
    case .notBrowserAccount:
        return [browserSignInHint(.storedAccount, jid: jid)]
    case .alreadyBrowserAccount:
        return [browserSignInAgainHint(jid: jid)]
    case .invalidJID, .invalidPort, .duplicateJID, .accountNotFound, .noStoredPassword, .notConnected, .moduleNotAvailable,
         .unencryptedConnection, nil:
        return []
    }
}

/// Prints `browserSignInAgainHint` for `jid` whenever an account joins `browserSignInNeeded`, as when a background
/// retry finds the provider rejects the grant. A CLI command connects one account, so the callback does not check
/// which.
@MainActor
func installBrowserSignInNeededHint(on accountService: AccountService, jid: String, report: @escaping (String) -> Void = { printToStandardError($0) }) {
    accountService.onBrowserSignInNeeded = { _ in
        report(browserSignInAgainHint(jid: jid))
    }
}

private func endpointArguments(host: String?, port: UInt16?) -> String {
    "\(host.map { " --host \($0)" } ?? "")\(port.map { " --port \($0)" } ?? "")"
}
