import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Gives each sign-in probe a fresh `MockTransport` on which `script` plays the server, and records the secret each
/// probe was built with. `replacingSecret` builds the client with that secret instead, so a probe can sign in.
private struct ProbeFactory: XMPPClientFactory {
    let replacingSecret: SignInSecret?
    let script: @Sendable (MockTransport) async -> Void
    private let secrets = OSAllocatedUnfairLock(initialState: [SignInSecret]())

    init(replacingSecret: SignInSecret? = nil, script: @escaping @Sendable (MockTransport) async -> Void) {
        self.replacingSecret = replacingSecret
        self.script = script
    }

    var probeSecrets: [SignInSecret] {
        secrets.withLock { $0 }
    }

    func makeClient(
        account: Account, secret: SignInSecret, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        secrets.withLock { $0.append(secret) }
        let transport = MockTransport()
        Task { await script(transport) }
        return await MockXMPPClientFactory(transport: transport, allowsPLAIN: replacingSecret == nil ? nil : true).makeClient(
            account: account, secret: replacingSecret ?? secret, resuming: resuming, requireTLSOverride: requireTLSOverride,
            omemoService: omemoService
        )
    }
}

/// Plays a server that offers `mechanism` after STARTTLS and refuses the empty token with `challenge`.
private func refuseBearerProbe(on transport: MockTransport, challenge: String? = SSOFixtures.challenge, mechanism: String = "OAUTHBEARER") async {
    await transport.waitForSent(count: 1) // stream opening
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive("<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>")
    await transport.waitForSent(count: 2) // starttls
    await transport.simulateReceive("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
    await transport.waitForSent(count: 3) // post-TLS stream opening
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(
        "<stream:features><mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>\(mechanism)</mechanism></mechanisms></stream:features>"
    )
    guard mechanism == "OAUTHBEARER" else { return }
    await transport.waitForSent(count: 4) // auth
    if let challenge {
        let encoded = Data(challenge.utf8).base64EncodedString()
        await transport.simulateReceive("<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(encoded)</challenge>")
        await transport.waitForSent(count: 5) // the challenge's acknowledgement
    }
    await transport.simulateReceive("<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><not-authorized/></failure>")
}

/// The test server's discovery, registration and token endpoints. Registration answers `register`, by default with
/// the public client `dcr-1`. `tokenStatus` other than 200 answers `invalid_grant`. Each token request records whether
/// the store held an administrator's client ID when it arrived.
private func providerHTTP(
    registration: Bool = true,
    register: @escaping @Sendable () -> ScriptedSSOHTTPClient.Reply = { (201, ["client_id": "dcr-1", "token_endpoint_auth_method": "none"]) },
    tokenStatus: Int = 200, store: MockCredentialStore, adminClientAtExchange: OSAllocatedUnfairLock<[Bool]>
) -> ScriptedSSOHTTPClient {
    .provider(registration: registration, register: register, token: { _ in
        let stored = try store.loadSecret(for: SSOStoreKey.adminClient(issuer: SSOFixtures.issuer)) != nil
        adminClientAtExchange.withLock { $0.append(stored) }
        if tokenStatus == 200 {
            return (200, SSOFixtures.tokenJSON())
        }
        return (tokenStatus, ["error": "invalid_grant"])
    })
}

@MainActor
struct SSOSignInServiceTests {
    private let jid = BareJID(localPart: "alice", domainPart: "example.com")!
    private let store = MockCredentialStore()
    private let adminClientAtExchange = OSAllocatedUnfairLock(initialState: [Bool]())
    private let adminKey = SSOStoreKey.adminClient(issuer: SSOFixtures.issuer)

    private func service(
        factory: ProbeFactory = ProbeFactory { await refuseBearerProbe(on: $0) }, http: ScriptedSSOHTTPClient,
        browser: FakeBrowserAuthorizer = FakeBrowserAuthorizer()
    ) -> SSOSignInService {
        SSOSignInService(
            clientFactory: factory, credentialStore: store, http: http,
            tokenClient: SSOTokenClient(http: http, credentialStore: store), browserAuthorizer: browser
        )
    }

    private func authorize(_ service: SSOSignInService, clientID: String? = nil) async throws -> SSOGrant {
        try await service.authorize(jid: jid, host: "127.0.0.1", port: 5222, clientID: clientID)
    }

    @Test
    func `A registered client signs in through the browser with the challenge's provider`() async throws {
        let factory = ProbeFactory { await refuseBearerProbe(on: $0) }
        let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
        let pages = OSAllocatedUnfairLock(initialState: [URL]())
        let browser = FakeBrowserAuthorizer { redirectURI, page, state in
            pages.withLock { $0.append(page) }
            var components = URLComponents(string: redirectURI)!
            components.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: state)]
            return components.url!
        }

        let grant = try await authorize(service(factory: factory, http: http, browser: browser))

        #expect(factory.probeSecrets == [.bearerToken("")])
        #expect(grant.clientID == "dcr-1")
        #expect(!grant.clientIsAdminSupplied)
        #expect(grant.accessToken == "access-1")
        #expect(browser.callCount == 1)
        let firstPage = pages.withLock { $0.first }
        let page = try #require(firstPage)
        let items = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "scope" }?.value == "xmpp offline_access")
        #expect(items.first { $0.name == "login_hint" }?.value == "alice@example.com")
        #expect(http.requests(to: "/oauth2/register").count == 1)
        #expect(try store.loadSecret(for: adminKey) == nil)
    }

    @Test
    func `A probe that signs in means the server does not offer browser sign-in`() async throws {
        let factory = ProbeFactory(replacingSecret: .password("secret")) { await simulateNoTLSConnect($0) }
        let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
        let browser = FakeBrowserAuthorizer()
        await #expect(throws: SSOError.serverUnsupported) { try await authorize(service(factory: factory, http: http, browser: browser)) }
        #expect(http.requests.isEmpty)
        #expect(browser.callCount == 0)
    }

    @Test
    func `A probe refused without a challenge means the server does not offer browser sign-in`() async throws {
        for factory in [
            ProbeFactory { await refuseBearerProbe(on: $0, challenge: nil) },
            ProbeFactory { await refuseBearerProbe(on: $0, mechanism: "SCRAM-SHA-1") }
        ] {
            let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
            await #expect(throws: SSOError.serverUnsupported) { try await authorize(service(factory: factory, http: http)) }
            #expect(http.requests.isEmpty)
        }
    }

    @Test
    func `A provider that does not let Ducko register asks for an administrator's client ID`() async throws {
        let http = providerHTTP(registration: false, store: store, adminClientAtExchange: adminClientAtExchange)
        let browser = FakeBrowserAuthorizer()
        await #expect(throws: SSOError.clientIDRequired(issuer: SSOFixtures.issuer)) {
            try await authorize(service(http: http, browser: browser))
        }
        #expect(browser.callCount == 0)
        #expect(http.requests(to: "/oauth2/token").isEmpty)
    }

    @Test(arguments: [401, 403])
    func `A registration refused without a JSON body asks for an administrator's client ID`(status: Int) async throws {
        let http = providerHTTP(
            register: { (status, Data("<html><body>Forbidden</body></html>".utf8)) }, store: store, adminClientAtExchange: adminClientAtExchange
        )
        let browser = FakeBrowserAuthorizer()
        await #expect(throws: SSOError.clientIDRequired(issuer: SSOFixtures.issuer)) {
            try await authorize(service(http: http, browser: browser))
        }
        #expect(http.requests(to: "/oauth2/register").count == 1)
        #expect(browser.callCount == 0)
    }

    @Test
    func `An administrator's client that cannot be read fails the sign-in instead of registering a client`() async throws {
        let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
        let browser = FakeBrowserAuthorizer()
        store.failSecretReads(true)
        await #expect(throws: SSOError.storeFailed) { try await authorize(service(http: http, browser: browser)) }
        #expect(http.requests(to: "/oauth2/register").isEmpty)
        #expect(browser.callCount == 0)
    }

    @Test
    func `A supplied client ID is stored only after the code exchange succeeds, then reused without asking`() async throws {
        let http = providerHTTP(registration: false, store: store, adminClientAtExchange: adminClientAtExchange)
        let service = service(http: http)

        let first = try await authorize(service, clientID: "admin-1")
        #expect(first.clientID == "admin-1")
        #expect(first.clientIsAdminSupplied)
        #expect(adminClientAtExchange.withLock { $0 } == [false])
        #expect(try store.loadSecret(for: adminKey) == Data("admin-1".utf8))

        let second = try await authorize(service)
        #expect(second.clientID == "admin-1")
        #expect(second.clientIsAdminSupplied)
        let exchanges = http.requests(to: "/oauth2/token").map { SSOFixtures.formFields($0)["client_id"] }
        #expect(exchanges == [["admin-1"], ["admin-1"]])
    }

    @Test
    func `A failed code exchange stores no client ID`() async throws {
        let http = providerHTTP(registration: false, tokenStatus: 400, store: store, adminClientAtExchange: adminClientAtExchange)
        await #expect(throws: SSOError.grantInvalid) { try await authorize(service(http: http), clientID: "admin-typo") }
        #expect(http.requests(to: "/oauth2/token").count == 1)
        #expect(try store.loadSecret(for: adminKey) == nil)
    }

    @Test
    func `A callback on another issuer's path makes no token request`() async throws {
        let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
        let otherPath = SSORedirect.callbackPath(forIssuer: "https://other.example.com")
        let browser = FakeBrowserAuthorizer { _, _, state in
            var components = URLComponents(string: "http://127.0.0.1:1234\(otherPath)")!
            components.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: state)]
            return components.url!
        }
        #expect(otherPath != SSORedirect.callbackPath(forIssuer: SSOFixtures.issuer))
        await #expect(throws: SSOError.malformedResponse) { try await authorize(service(http: http, browser: browser)) }
        #expect(browser.callCount == 1)
        #expect(http.requests(to: "/oauth2/token").isEmpty)
    }

    @Test
    func `The challenge's scope is requested, with offline_access where listed`() async throws {
        let challenge = #"{"status":"invalid_token","scope":"xmpp:custom","openid-configuration":"https://auth.example.com/.well-known/oauth-authorization-server"}"#
        let factory = ProbeFactory { await refuseBearerProbe(on: $0, challenge: challenge) }
        let http = providerHTTP(store: store, adminClientAtExchange: adminClientAtExchange)
        let scopes = OSAllocatedUnfairLock(initialState: [String?]())
        let browser = FakeBrowserAuthorizer { redirectURI, page, state in
            scopes.withLock { $0.append(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value) }
            var components = URLComponents(string: redirectURI)!
            components.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: state)]
            return components.url!
        }
        _ = try await authorize(service(factory: factory, http: http, browser: browser))
        #expect(scopes.withLock { $0 } == ["xmpp:custom offline_access"])
    }
}
