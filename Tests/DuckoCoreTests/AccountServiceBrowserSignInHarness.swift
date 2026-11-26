import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// Fixtures for the `AccountService` browser sign-in suites: a scripted XMPP server behind STARTTLS that judges each
// bearer token, a scripted provider, and the service wired to both.

let browserJID = BareJID(localPart: "alice", domainPart: "example.com")!
let candidateAccess = "candidate-access"
let candidateRefresh = "candidate-refresh"
let storedAccess = "stored-access"
let storedRefresh = "stored-refresh"
let refreshedAccess = "refreshed-access"

/// Builds each client on a fresh `MockTransport` that plays a server offering STARTTLS, then OAUTHBEARER and PLAIN. The
/// empty probe token gets the bearer challenge, other tokens what `verdict` says, and PLAIN always succeeds. Records
/// every client it builds.
actor BrowserServerFactory: XMPPClientFactory {
    enum Verdict: Sendable {
        case accept(bound: String)
        case reject
        case temporary

        static let acceptAlice = Verdict.accept(bound: "alice@example.com/ducko")
    }

    struct Request {
        let secret: SignInSecret
        let transport: MockTransport
        let requireTLS: Bool?
    }

    private let verdict: @Sendable (String) -> Verdict
    private var holds: [String: SetupHold] = [:]
    private(set) var requests: [Request] = []

    init(verdict: @escaping @Sendable (String) -> Verdict = { _ in .acceptAlice }) {
        self.verdict = verdict
    }

    /// Holds the setup of the next client signing in with `token`, once it is connected, until `release` is signaled,
    /// then fails it with `failure` when given.
    func holdSetup(ofToken token: String, failure: (any Error)? = nil) -> (entered: AsyncSemaphore, release: AsyncSemaphore) {
        let gate = (entered: AsyncSemaphore(), release: AsyncSemaphore())
        holds[token] = SetupHold(entered: gate.entered, release: gate.release, failure: failure)
        return gate
    }

    var secrets: [SignInSecret] {
        requests.map(\.secret)
    }

    /// The bearer tokens clients were built with, without the probe's empty one.
    var bearerTokens: [String] {
        requests.compactMap {
            guard case let .bearerToken(token) = $0.secret, !token.isEmpty else { return nil }
            return token
        }
    }

    var lastTransport: MockTransport? {
        requests.last?.transport
    }

    func makeClient(
        account: Account, secret: SignInSecret, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService _: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        let transport = MockTransport()
        await transport.setTLSInfo(TLSInfo(protocolVersion: "TLS 1.3", wireVersion: 0x0304, cipherSuite: nil))
        await serveSignIn(on: transport, verdict: verdict)
        var builder = XMPPClientBuilder(domain: account.jid.domainPart, username: account.jid.localPart ?? "", secret: secret)
        builder.withTransport(transport)
        builder.withRequireTLS(requireTLSOverride ?? false)
        builder.withAllowsPLAIN(true)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        builder.withModule(RegistrationModule())
        if case let .bearerToken(token) = secret, let gate = holds.removeValue(forKey: token) {
            builder.withModule(gate)
        }
        requests.append(Request(secret: secret, transport: transport, requireTLS: requireTLSOverride))
        return await (builder.build(), sm)
    }
}

private let saslNamespace = "urn:ietf:params:xml:ns:xmpp-sasl"

/// Plays the server side of a sign-in on `transport`, answering each stanza from inside its send.
private func serveSignIn(on transport: MockTransport, verdict: @escaping @Sendable (String) -> BrowserServerFactory.Verdict) async {
    let streamOpenings = OSAllocatedUnfairLock(initialState: 0)
    let bound = OSAllocatedUnfairLock(initialState: "alice@example.com/ducko")
    await transport.autoReply { stanza in
        if stanza.contains("<stream:stream") {
            let opening = streamOpenings.withLock { count in
                count += 1
                return count
            }
            switch opening {
            case 1:
                return testServerStreamOpen + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>"
            case 2:
                return testServerStreamOpen + "<stream:features><mechanisms xmlns='\(saslNamespace)'>"
                    + "<mechanism>OAUTHBEARER</mechanism><mechanism>PLAIN</mechanism></mechanisms></stream:features>"
            default:
                return testServerStreamOpen + testFeaturesBind
            }
        }
        if stanza.hasPrefix("<starttls") {
            return "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>"
        }
        if stanza.hasPrefix("<auth") {
            guard stanza.contains("OAUTHBEARER") else { return "<success xmlns='\(saslNamespace)'/>" }
            let token = bearerToken(inAuth: stanza) ?? ""
            if token.isEmpty { return bearerChallenge() }
            switch verdict(token) {
            case let .accept(jid):
                bound.withLock { $0 = jid }
                return "<success xmlns='\(saslNamespace)'/>"
            case .reject:
                return bearerChallenge()
            case .temporary:
                return "<failure xmlns='\(saslNamespace)'><temporary-auth-failure/></failure>"
            }
        }
        if stanza.hasPrefix("<response") {
            return "<failure xmlns='\(saslNamespace)'><not-authorized/></failure>"
        }
        if stanza.hasPrefix("<iq"), let id = extractIQID(from: stanza) {
            if stanza.contains("urn:ietf:params:xml:ns:xmpp-bind") {
                let jid = bound.withLock { $0 }
                return "<iq type='result' id='\(id)'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><jid>\(jid)</jid></bind></iq>"
            }
            if stanza.contains(XMPPNamespaces.register), stanza.contains("type=\"set\"") {
                return "<iq type='result' id='\(id)'/>"
            }
        }
        return nil
    }
}

private func bearerChallenge() -> String {
    "<challenge xmlns='\(saslNamespace)'>\(Data(SSOFixtures.challenge.utf8).base64EncodedString())</challenge>"
}

/// The token of an OAUTHBEARER initial response (RFC 7628 §3.1).
private func bearerToken(inAuth stanza: String) -> String? {
    guard let start = stanza.firstIndex(of: ">"), let end = stanza.range(of: "</auth>"),
          let data = Data(base64Encoded: String(stanza[stanza.index(after: start) ..< end.lowerBound])) else { return nil }
    let message = String(decoding: data, as: UTF8.self)
    guard let key = message.range(of: "auth=Bearer ") else { return nil }
    return String(message[key.upperBound...].prefix { $0 != "\u{1}" })
}

// MARK: - Provider

enum RefreshReply {
    case tokens
    case invalidGrant
    case unreachable
}

/// The provider's side: code exchanges issuing `candidates` in turn (the last one again once they run out), refreshes
/// answered with `refresh` after `onRefresh` returns, and revocation, which first runs `onRevoke`.
func makeProvider(
    candidates: [(access: String, refresh: String)] = [(candidateAccess, candidateRefresh)], candidateExpiresIn: Int = 3600,
    refresh: RefreshReply = .tokens, onRevoke: (@Sendable () async -> Void)? = nil, onRefresh: (@Sendable () async -> Void)? = nil
) -> ScriptedSSOHTTPClient {
    let exchanges = OSAllocatedUnfairLock(initialState: 0)
    return .provider(
        token: { fields in
            if fields["grant_type"] == ["authorization_code"] {
                let index = exchanges.withLock { count in
                    defer { count += 1 }
                    return min(count, candidates.count - 1)
                }
                let candidate = candidates[index]
                return (200, SSOFixtures.tokenJSON(access: candidate.access, refresh: candidate.refresh, expiresIn: candidateExpiresIn))
            }
            await onRefresh?()
            switch refresh {
            case .tokens:
                return (200, SSOFixtures.tokenJSON(access: refreshedAccess, refresh: "refreshed-refresh"))
            case .invalidGrant:
                return (400, ["error": "invalid_grant"])
            case .unreachable:
                return (503, [String: String]())
            }
        },
        revoke: {
            await onRevoke?()
            return (200, [String: String]())
        }
    )
}

extension ScriptedSSOHTTPClient {
    /// The tokens revocation requests carried.
    var revokedTokens: [String] {
        requests(to: "/oauth2/revoke").compactMap { SSOFixtures.formFields($0)["token"]?.first }
    }

    /// The refresh tokens refresh requests carried.
    var refreshedTokens: [String] {
        requests(to: "/oauth2/token").compactMap {
            let fields = SSOFixtures.formFields($0)
            return fields["grant_type"] == ["refresh_token"] ? fields["refresh_token"]?.first : nil
        }
    }
}

/// A browser whose sign-in waits, once entered, until released, then approves.
func holdingBrowser(entered: AsyncSemaphore, release: AsyncSemaphore) -> FakeBrowserAuthorizer {
    FakeBrowserAuthorizer { redirectURI, _, state in
        await entered.signal()
        await release.wait()
        var components = URLComponents(string: redirectURI)!
        components.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: state)]
        return components.url!
    }
}

// MARK: - Service

/// An `AccountService` over a scripted server and provider, retrying at once.
@MainActor
struct BrowserSignInHarness {
    let store: MockPersistenceStore
    let credentials: MockCredentialStore
    let factory: BrowserServerFactory
    let provider: ScriptedSSOHTTPClient
    let browser: FakeBrowserAuthorizer
    let service: AccountService

    init(
        store: MockPersistenceStore = MockPersistenceStore(), credentials: MockCredentialStore = MockCredentialStore(),
        credentialStore: (any CredentialStore)? = nil, persistence: (any PersistenceStore)? = nil,
        factory: BrowserServerFactory = BrowserServerFactory(), provider: ScriptedSSOHTTPClient = makeProvider(),
        browser: FakeBrowserAuthorizer = FakeBrowserAuthorizer()
    ) {
        self.store = store
        self.credentials = credentials
        self.factory = factory
        self.provider = provider
        self.browser = browser
        self.service = AccountService(
            store: persistence ?? store, credentialStore: credentialStore ?? credentials, clientFactory: factory, networkPath: nil,
            browserAuthorizer: browser, ssoHTTPClient: provider
        )
        service.reconnectDelay = { _ in .milliseconds(10) }
    }

    /// Stores an account signing in with `method`, with a stored grant for a browser account and a stored password
    /// for a password account, and loads it.
    func addAccount(
        _ method: SignInMethod, grant: SSOGrant = SSOFixtures.grant(access: storedAccess, refresh: storedRefresh)
    ) async throws -> UUID {
        let account = Account(id: UUID(), jid: browserJID, isEnabled: true, connectOnLaunch: false, signInMethod: method, createdAt: Date())
        try await store.saveAccount(account)
        switch method {
        case .browser:
            try credentials.saveGrant(grant, for: browserJID)
        case .password:
            credentials.savePassword("secret", for: browserJID.description)
        }
        try await service.loadAccounts()
        return account.id
    }

    var storedGrant: SSOGrant? {
        get throws { try credentials.loadGrant(for: browserJID) }
    }

    func isConnected(_ id: UUID) -> Bool {
        if case .connected = service.connectionStates[id] { return true }
        return false
    }

    /// Whether a reconnect or redirect is scheduled or running for the account.
    func reconnectPending(_ id: UUID) -> Bool {
        service.connectionResources[id]?.reconnectTask != nil || service.connectionResources[id]?.retryDue != nil
    }
}
