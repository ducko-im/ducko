import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// A clock a test moves by hand.
private final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date {
        current.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(interval) }
    }
}

/// A token endpoint whose answers wait for the test. Request `index` is answered once `gates[index]` is signaled, and
/// requests past the last gate are answered at once.
private final class HeldTokenEndpoint: Sendable {
    let gates: [AsyncSemaphore]
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(gates: Int) {
        self.gates = (0 ..< gates).map { _ in AsyncSemaphore() }
    }

    /// A client playing this endpoint, answering request `index` with `reply(index)`.
    func http(_ reply: @escaping @Sendable (Int) -> ScriptedSSOHTTPClient.Reply) -> ScriptedSSOHTTPClient {
        ScriptedSSOHTTPClient { [gates, count] _ in
            let index = count.withLock { value in
                defer { value += 1 }
                return value
            }
            if index < gates.count { await gates[index].wait() }
            return reply(index)
        }
    }
}

struct SSOTokenProviderTests {
    private let clock = TestClock()
    private let store = MockCredentialStore()
    private let account = Account(
        id: UUID(), jid: BareJID(localPart: "alice", domainPart: "example.com")!, isEnabled: true, connectOnLaunch: false,
        signInMethod: .browser, createdAt: Date()
    )

    private func provider(_ http: ScriptedSSOHTTPClient) -> SSOTokenProvider {
        let clock = clock
        let tokenClient = SSOTokenClient(http: http, credentialStore: store, now: { clock.now })
        return SSOTokenProvider(credentialStore: store, tokenClient: tokenClient)
    }

    /// Stores a grant whose access token expires `expiresIn` seconds from now.
    private func storeGrant(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: TimeInterval?) throws {
        try store.saveGrant(SSOFixtures.grant(access: access, refresh: refresh, expiresAt: expiresIn.map { clock.now.addingTimeInterval($0) }), for: account.jid)
    }

    private func waitForRequests(_ http: ScriptedSSOHTTPClient, count: Int) async throws {
        try await eventually { http.requests.count >= count }
    }

    @Test
    func `A token well before its expiry is used without a request`() async throws {
        try storeGrant(expiresIn: 3600)
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2")) }
        let result = try await provider(http).validAccessToken(for: account)
        #expect(result.token == "access-1")
        #expect(!result.refreshedNow)
        #expect(http.requests.isEmpty)
    }

    @Test
    func `A missing grant is invalid`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON()) }
        await #expect(throws: SSOError.grantInvalid) { try await provider(http).validAccessToken(for: account) }
    }

    @Test
    func `Two concurrent calls near expiry make one refresh request`() async throws {
        try storeGrant(expiresIn: 30)
        let endpoint = HeldTokenEndpoint(gates: 2)
        let http = endpoint.http { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        let provider = provider(http)
        let account = account

        let first = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        let second = Task { try await provider.validAccessToken(for: account) }
        // Long enough for the second call to send a request of its own if it did not join the first.
        try await Task.sleep(for: .milliseconds(200))
        await endpoint.gates[0].signal()
        await endpoint.gates[1].signal()

        let results = try await [first.value, second.value]
        #expect(results.map(\.token) == ["access-2", "access-2"])
        #expect(http.requests.count == 1)
        #expect(try store.loadGrant(for: account.jid)?.refreshToken == "refresh-2")
    }

    @Test
    func `An unreachable provider leaves an unexpired token in use`() async throws {
        try storeGrant(expiresIn: 30)
        let http = ScriptedSSOHTTPClient { _ in (503, ["error": "temporarily_unavailable"]) }
        let result = try await provider(http).validAccessToken(for: account)
        #expect(result.token == "access-1")
        #expect(!result.refreshedNow)
        #expect(http.requests.count == 1)
        #expect(try store.loadGrant(for: account.jid)?.accessToken == "access-1")
    }

    @Test
    func `A refresh whose result cannot be stored fails, even while the old token has not expired`() async throws {
        try storeGrant(expiresIn: 30)
        store.failSecretWrites(saves: true)
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }

        await #expect(throws: SSOError.storeFailed) { try await provider(http).validAccessToken(for: account) }
        #expect(http.requests.count == 1)
        #expect(try store.loadGrant(for: account.jid)?.accessToken == "access-1")
    }

    @Test
    func `An unreachable provider with an expired token fails`() async throws {
        try storeGrant(expiresIn: -1)
        let http = ScriptedSSOHTTPClient { _ in (503, ["error": "temporarily_unavailable"]) }
        await #expect(throws: SSOError.providerUnreachable) { try await provider(http).validAccessToken(for: account) }
    }

    @Test
    func `A grant without a refresh token is used until its expiry, then is invalid without a request`() async throws {
        try storeGrant(refresh: nil, expiresIn: 30)
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2")) }
        let provider = provider(http)

        #expect(try await provider.validAccessToken(for: account).token == "access-1")
        clock.advance(by: 31)
        await #expect(throws: SSOError.grantInvalid) { try await provider.validAccessToken(for: account) }
        await #expect(throws: SSOError.grantInvalid) { try await provider.forceRefresh(for: account) }
        #expect(http.requests.isEmpty)
    }

    @Test
    func `invalid_grant after another provider rotated the stored grant recovers from the store`() async throws {
        try storeGrant(expiresIn: 30)
        // The first refresh-1 request rotates the grant; the second, sent with the same now spent token, is refused.
        let endpoint = HeldTokenEndpoint(gates: 2)
        let http = endpoint.http { index in
            index == 0 ? (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) : (400, ["error": "invalid_grant"])
        }
        let providerA = provider(http)
        let providerB = provider(http)
        let account = account

        let first = Task { try await providerA.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        let second = Task { try await providerB.validAccessToken(for: account) }
        try await waitForRequests(http, count: 2)

        await endpoint.gates[0].signal()
        #expect(try await first.value.token == "access-2")
        await endpoint.gates[1].signal()
        #expect(try await second.value.token == "access-2")

        #expect(http.requests.count == 2)
        #expect(http.requests.allSatisfy { SSOFixtures.formFields($0)["refresh_token"] == ["refresh-1"] })
        #expect(try store.loadGrant(for: account.jid)?.refreshToken == "refresh-2")
    }

    @Test
    func `A refresh that finds the grant replaced returns the stored grant's token and keeps it`() async throws {
        try storeGrant(expiresIn: 30)
        let endpoint = HeldTokenEndpoint(gates: 1)
        let http = endpoint.http { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        let provider = provider(http)
        let account = account

        let refresh = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        try storeGrant(access: "access-new", refresh: "refresh-new", expiresIn: 3600)
        await endpoint.gates[0].signal()

        #expect(try await refresh.value.token == "access-new")
        let stored = try store.loadGrant(for: account.jid)
        #expect(stored?.accessToken == "access-new")
        #expect(stored?.refreshToken == "refresh-new")
        #expect(http.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func `A replacement grant that is due too is refreshed once more with its own refresh token`(firstRefused: Bool) async throws {
        try storeGrant(expiresIn: 30)
        let endpoint = HeldTokenEndpoint(gates: 1)
        let http = endpoint.http { index in
            switch (index, firstRefused) {
            case (0, true): (400, ["error": "invalid_grant"])
            case (0, false): (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
            default: (200, SSOFixtures.tokenJSON(access: "access-3", refresh: "refresh-3"))
            }
        }
        let provider = provider(http)
        let account = account

        let refresh = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        // Another process replaced the grant with one whose token is about to expire as well.
        try storeGrant(access: "access-new", refresh: "refresh-new", expiresIn: 30)
        await endpoint.gates[0].signal()

        #expect(try await refresh.value.token == "access-3")
        #expect(http.requests.map { SSOFixtures.formFields($0)["refresh_token"] } == [["refresh-1"], ["refresh-new"]])
        #expect(try store.loadGrant(for: account.jid)?.refreshToken == "refresh-3")
    }

    struct TemporaryRefusal: Sendable, CustomTestStringConvertible {
        let status: Int
        /// Whether the body is an HTML page rather than JSON.
        let html: Bool
        let errorOnceExpired: SSOError

        var testDescription: String {
            "\(status) \(html ? "HTML" : "JSON")"
        }
    }

    @Test(arguments: [
        TemporaryRefusal(status: 429, html: false, errorOnceExpired: .providerUnreachable),
        TemporaryRefusal(status: 429, html: true, errorOnceExpired: .providerUnreachable),
        TemporaryRefusal(status: 400, html: true, errorOnceExpired: .malformedResponse),
        TemporaryRefusal(status: 403, html: true, errorOnceExpired: .malformedResponse)
    ])
    func `A refresh refused without refusing the grant leaves an unexpired token in use, then fails once it expired`(
        refusal: TemporaryRefusal
    ) async throws {
        try storeGrant(expiresIn: 30)
        let http = ScriptedSSOHTTPClient { _ -> ScriptedSSOHTTPClient.Reply in
            if refusal.html {
                return (refusal.status, Data("<html><body>Try again later</body></html>".utf8))
            }
            return (refusal.status, ["error": "slow_down"])
        }
        let provider = provider(http)

        let result = try await provider.validAccessToken(for: account)
        #expect(result.token == "access-1")
        #expect(!result.refreshedNow)
        clock.advance(by: 31)
        await #expect(throws: refusal.errorOnceExpired) { try await provider.validAccessToken(for: account) }
        #expect(try store.loadGrant(for: account.jid)?.accessToken == "access-1")
    }

    @Test(arguments: [false, true])
    func `A store that cannot be read back after a refresh fails it as storeFailed`(refused: Bool) async throws {
        // Expired, so the failure is not covered by a token still in use.
        try storeGrant(expiresIn: -1)
        let endpoint = HeldTokenEndpoint(gates: 1)
        let http = endpoint.http { _ in
            refused ? (400, ["error": "invalid_grant"]) : (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2"))
        }
        let provider = provider(http)
        let account = account

        let refresh = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        store.failSecretReads(true)
        await endpoint.gates[0].signal()

        await #expect(throws: SSOError.storeFailed) { try await refresh.value }
    }

    @Test
    func `A refresh held across deletion of the grant writes nothing back`() async throws {
        try storeGrant(expiresIn: 30)
        let endpoint = HeldTokenEndpoint(gates: 1)
        let http = endpoint.http { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        let provider = provider(http)
        let account = account

        let refresh = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        try store.deleteGrant(for: account.jid)
        await endpoint.gates[0].signal()

        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(try store.loadGrant(for: account.jid) == nil)
    }

    @Test
    func `A refresh invalidated while held, as account deletion does, writes nothing back`() async throws {
        try storeGrant(expiresIn: 30)
        let endpoint = HeldTokenEndpoint(gates: 1)
        let http = endpoint.http { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        let provider = provider(http)
        let account = account

        let refresh = Task { try await provider.validAccessToken(for: account) }
        try await waitForRequests(http, count: 1)
        await provider.invalidate(accountID: account.id)
        await endpoint.gates[0].signal()

        await #expect(throws: CancellationError.self) { try await refresh.value }
        #expect(try store.loadGrant(for: account.jid)?.refreshToken == "refresh-1")
    }

    @Test
    func `A forced refresh refreshes a token far from its expiry`() async throws {
        try storeGrant(expiresIn: 3600)
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        #expect(try await provider(http).forceRefresh(for: account) == "access-2")
        #expect(http.requests.count == 1)
        #expect(try store.loadGrant(for: account.jid)?.accessToken == "access-2")
    }
}
