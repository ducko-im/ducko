import DuckoCore
import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCLI

struct SignInHintsTests {
    @Test
    func `A stored account's hint names account set`() {
        #expect(plainRefusalHint(.storedAccount, jid: "alice@example.com") == "Run 'ducko account set alice@example.com --allow-plain' to send the password to this server.")
    }

    @Test
    func `account add's hint re-runs it with --allow-plain and never names account set`() {
        let hint = plainRefusalHint(.accountAdd(host: nil, port: nil), jid: "alice@example.com")
        #expect(hint.contains("ducko account add alice@example.com --allow-plain"))
        #expect(!hint.contains("account set"))
    }

    @Test
    func `account add's hint keeps the host and port it was given`() {
        let hint = plainRefusalHint(.accountAdd(host: "xmpp.example.net", port: 5299), jid: "alice@example.com")
        #expect(hint.contains("ducko account add alice@example.com --host xmpp.example.net --port 5299 --allow-plain"))
    }

    @Test
    func `A stored account's browser hint names browser-sign-in with --replace-password`() {
        #expect(browserSignInHint(.storedAccount, jid: "alice@example.com")
            == "Run 'ducko account browser-sign-in alice@example.com --replace-password' to switch this account to browser sign-in.")
    }

    @Test
    func `account add's browser hint re-runs it with --sso`() {
        #expect(browserSignInHint(.accountAdd(host: nil, port: nil), jid: "alice@example.com")
            == "Run 'ducko account add alice@example.com --sso' to sign in through the browser.")
    }

    @Test
    func `account add's browser hint keeps the host and port it was given`() {
        #expect(browserSignInHint(.accountAdd(host: "xmpp.example.net", port: 5299), jid: "alice@example.com")
            == "Run 'ducko account add alice@example.com --host xmpp.example.net --port 5299 --sso' to sign in through the browser.")
        #expect(browserSignInHint(.accountAdd(host: "xmpp.example.net", port: nil), jid: "alice@example.com")
            == "Run 'ducko account add alice@example.com --host xmpp.example.net --sso' to sign in through the browser.")
    }

    @Test
    func `A grant that needs a new sign-in names browser-sign-in`() {
        #expect(browserSignInAgainHint(jid: "alice@example.com") == "Run 'ducko account browser-sign-in alice@example.com' to sign in again.")
    }

    @Test
    func `An expired grant, or one the service marked as needing a new sign-in, gets the sign-in-again hint`() {
        let again = [browserSignInAgainHint(jid: "alice@example.com")]
        #expect(signInFailureHints(for: SSOError.grantInvalid, .storedAccount, jid: "alice@example.com") == again)
        #expect(signInFailureHints(for: SSOError.providerUnreachable, .storedAccount, jid: "alice@example.com", browserSignInNeeded: true) == again)
        #expect(signInFailureHints(for: SSOError.providerUnreachable, .storedAccount, jid: "alice@example.com").isEmpty)
    }

    @Test
    func `A provider that needs a client ID names its issuer, both redirect addresses, and --client-id`() throws {
        let issuer = "https://auth.example.com"
        let lines = browserSignInFailureHints(for: SSOError.clientIDRequired(issuer: issuer), jid: "alice@example.com")
        let uris = SSORedirect.redirectURIs(forIssuer: issuer)
        try #require(uris.count == 2)
        #expect(lines.first?.contains(issuer) == true, Comment(rawValue: lines.joined(separator: "\n")))
        for uri in uris {
            #expect(lines.contains("  \(uri)"), Comment(rawValue: lines.joined(separator: "\n")))
        }
        #expect(lines.last?.contains("--client-id <id>") == true, Comment(rawValue: lines.joined(separator: "\n")))
    }

    @Test
    func `browser-sign-in names the invocation that matches how the account signs in`() {
        #expect(browserSignInFailureHints(for: AccountService.AccountServiceError.notBrowserAccount("alice@example.com"), jid: "alice@example.com")
            == [browserSignInHint(.storedAccount, jid: "alice@example.com")])
        #expect(browserSignInFailureHints(for: AccountService.AccountServiceError.alreadyBrowserAccount("alice@example.com"), jid: "alice@example.com")
            == [browserSignInAgainHint(jid: "alice@example.com")])
        #expect(browserSignInFailureHints(for: SSOError.cancelled, jid: "alice@example.com").isEmpty)
    }

    @MainActor
    @Test
    func `The hook interactive installs prints the sign-in-again hint`() {
        let service = AccountService(store: MockPersistenceStore(), credentialStore: NullCredentialStore())
        var printed: [String] = []
        installBrowserSignInNeededHint(on: service, jid: "alice@example.com") { printed.append($0) }

        service.onBrowserSignInNeeded?(UUID())

        #expect(printed == [browserSignInAgainHint(jid: "alice@example.com")])
    }
}
