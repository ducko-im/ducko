import Foundation
import Testing
@testable import DuckoCore

struct SSOTokenClientTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func client(_ http: ScriptedSSOHTTPClient, store: MockCredentialStore = MockCredentialStore()) -> SSOTokenClient {
        SSOTokenClient(http: http, credentialStore: store, now: { now })
    }

    private static func request() throws -> SSOAuthorizationRequest {
        let metadata = try AuthorizationServerMetadata(json: SSOFixtures.metadataJSON(), expectedIssuers: [SSOFixtures.issuer])
        return SSOAuthorizationRequest(metadata: metadata, clientID: "client-1", challengeScope: nil, loginHint: "alice@example.com")
    }

    @Test
    func `The code exchange posts the code, redirect URI, client and verifier`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON()) }
        let request = try Self.request()
        let grant = try await Self.client(http).exchange(
            code: "the-code", request: request, redirectURI: "http://127.0.0.1:1/cb", clientIsAdminSupplied: false
        )
        let fields = try SSOFixtures.formFields(#require(http.requests.first))
        #expect(fields["grant_type"] == ["authorization_code"])
        #expect(fields["code"] == ["the-code"])
        #expect(fields["redirect_uri"] == ["http://127.0.0.1:1/cb"])
        #expect(fields["client_id"] == ["client-1"])
        #expect(fields["code_verifier"] == [request.codeVerifier])
        #expect(grant.accessToken == "access-1")
        #expect(grant.refreshToken == "refresh-1")
        #expect(grant.expiresAt == Self.now.addingTimeInterval(3600))
        #expect(grant.issuer == SSOFixtures.issuer)
    }

    @Test
    func `A refresh answered without a refresh token keeps the previous one`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: nil)) }
        let refreshed = try await Self.client(http).refresh(SSOFixtures.grant(refresh: "refresh-1"))
        #expect(refreshed.accessToken == "access-2")
        #expect(refreshed.refreshToken == "refresh-1")
        let fields = try SSOFixtures.formFields(#require(http.requests.first))
        #expect(fields["grant_type"] == ["refresh_token"])
        #expect(fields["refresh_token"] == ["refresh-1"])
        #expect(fields["client_id"] == ["client-1"])
    }

    @Test
    func `A rotated refresh token replaces the previous one`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "access-2", refresh: "refresh-2")) }
        let refreshed = try await Self.client(http).refresh(SSOFixtures.grant(refresh: "refresh-1"))
        #expect(refreshed.refreshToken == "refresh-2")
    }

    @Test(arguments: ["mac", "", "DPoP"])
    func `A token type other than bearer is refused`(tokenType: String) async throws {
        let http = ScriptedSSOHTTPClient { _ in
            var body = SSOFixtures.tokenJSON()
            body["token_type"] = tokenType
            return (200, body)
        }
        await #expect(throws: SSOError.malformedResponse) { try await Self.client(http).refresh(SSOFixtures.grant()) }
        await #expect(throws: SSOError.malformedResponse) {
            try await Self.client(http).exchange(code: "c", request: Self.request(), redirectURI: "http://127.0.0.1:1/cb", clientIsAdminSupplied: false)
        }
    }

    @Test
    func `The token type is matched case-insensitively`() async throws {
        let http = ScriptedSSOHTTPClient { _ in
            var body = SSOFixtures.tokenJSON()
            body["token_type"] = "bEaReR"
            return (200, body)
        }
        #expect(try await Self.client(http).refresh(SSOFixtures.grant()).accessToken == "access-1")
    }

    @Test
    func `A missing or empty access token is refused`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(access: "")) }
        await #expect(throws: SSOError.malformedResponse) { try await Self.client(http).refresh(SSOFixtures.grant()) }
    }

    @Test
    func `A missing expires_in gives an unknown expiry`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(expiresIn: nil)) }
        let grant = try await Self.client(http).exchange(
            code: "c", request: Self.request(), redirectURI: "http://127.0.0.1:1/cb", clientIsAdminSupplied: false
        )
        #expect(grant.expiresAt == nil)
        let refreshed = try await Self.client(http).refresh(SSOFixtures.grant())
        #expect(refreshed.expiresAt == nil)
    }

    @Test
    func `A code exchange without a refresh token is accepted`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON(refresh: nil)) }
        let grant = try await Self.client(http).exchange(
            code: "c", request: Self.request(), redirectURI: "http://127.0.0.1:1/cb", clientIsAdminSupplied: false
        )
        #expect(grant.refreshToken == nil)
    }

    @Test
    func `A grant without a refresh token cannot be refreshed and sends nothing`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.tokenJSON()) }
        await #expect(throws: SSOError.grantInvalid) { try await Self.client(http).refresh(SSOFixtures.grant(refresh: nil)) }
        #expect(http.requests.isEmpty)
    }

    struct FailureCase: Sendable, CustomTestStringConvertible {
        let status: Int
        let error: String
        let expected: SSOError

        var testDescription: String {
            "\(status) \(error)"
        }
    }

    @Test(arguments: [
        FailureCase(status: 400, error: "invalid_grant", expected: .grantInvalid),
        FailureCase(status: 401, error: "invalid_client", expected: .grantInvalid),
        FailureCase(status: 400, error: "invalid_request", expected: .malformedResponse),
        FailureCase(status: 503, error: "temporarily_unavailable", expected: .providerUnreachable)
    ])
    func `Token endpoint failures map to their class`(failure: FailureCase) async throws {
        let http = ScriptedSSOHTTPClient { _ in (failure.status, ["error": failure.error]) }
        await #expect(throws: failure.expected) { try await Self.client(http).refresh(SSOFixtures.grant()) }
    }

    @Test
    func `invalid_client with an administrator's client forgets that client`() async throws {
        let store = MockCredentialStore()
        let key = SSOStoreKey.adminClient(issuer: SSOFixtures.issuer)
        try store.saveSecret(Data("client-1".utf8), for: key)
        let http = ScriptedSSOHTTPClient { _ in (401, ["error": "invalid_client"]) }
        await #expect(throws: SSOError.grantInvalid) {
            try await Self.client(http, store: store).refresh(SSOFixtures.grant(adminClient: true))
        }
        #expect(try store.loadSecret(for: key) == nil)
        #expect(key == "sso-admin-client:\(SSOFixtures.issuer)")
    }

    @Test
    func `invalid_client with an administrator's client keeps a different client remembered since`() async throws {
        let store = MockCredentialStore()
        let key = SSOStoreKey.adminClient(issuer: SSOFixtures.issuer)
        try store.saveSecret(Data("client-2".utf8), for: key)
        let http = ScriptedSSOHTTPClient { _ in (401, ["error": "invalid_client"]) }
        await #expect(throws: SSOError.grantInvalid) {
            try await Self.client(http, store: store).refresh(SSOFixtures.grant(adminClient: true))
        }
        #expect(try store.loadSecret(for: key) == Data("client-2".utf8))
    }

    @Test
    func `invalid_client with a registered client leaves a stored administrator's client alone`() async throws {
        let store = MockCredentialStore()
        let key = SSOStoreKey.adminClient(issuer: SSOFixtures.issuer)
        try store.saveSecret(Data("admin".utf8), for: key)
        let http = ScriptedSSOHTTPClient { _ in (401, ["error": "invalid_client"]) }
        await #expect(throws: SSOError.grantInvalid) {
            try await Self.client(http, store: store).refresh(SSOFixtures.grant(adminClient: false))
        }
        #expect(try store.loadSecret(for: key) == Data("admin".utf8))
    }

    @Test
    func `Revocation sends the refresh token, else the access token`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, [String: String]()) }
        let client = Self.client(http)
        try await client.revoke(SSOFixtures.grant(access: "a", refresh: "r"))
        try await client.revoke(SSOFixtures.grant(access: "a", refresh: nil))
        let fields = http.requests.map { SSOFixtures.formFields($0) }
        #expect(fields.map { $0["token"] } == [["r"], ["a"]])
        #expect(fields.map { $0["token_type_hint"] } == [["refresh_token"], ["access_token"]])
        #expect(http.requests.allSatisfy { $0.url == URL(string: "https://auth.example.com/oauth2/revoke") })
    }
}
