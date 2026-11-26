import CryptoKit
import Foundation
import Testing
@testable import DuckoCore

struct SSOAuthorizationRequestTests {
    private static func request(
        scopes: [String]? = ["xmpp", "offline_access", "openid"], challengeScope: String? = nil, issParameter: Bool = false
    ) throws -> SSOAuthorizationRequest {
        var json = SSOFixtures.metadataJSON(scopes: scopes)
        if issParameter { json["authorization_response_iss_parameter_supported"] = true }
        let metadata = try AuthorizationServerMetadata(json: json, expectedIssuers: [SSOFixtures.issuer])
        return SSOAuthorizationRequest(metadata: metadata, clientID: "client-1", challengeScope: challengeScope, loginHint: "alice@example.com")
    }

    private static func redirectURI(for request: SSOAuthorizationRequest) -> String {
        "http://127.0.0.1:1234\(request.callbackPath)"
    }

    private static func callback(_ base: String, _ items: [(String, String)]) throws -> URL {
        var components = try #require(URLComponents(string: base))
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return try #require(components.url)
    }

    private static func queryItems(of url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { first, _ in first }
    }

    // MARK: - PKCE and URL

    @Test
    func `The S256 challenge is the SHA-256 of the verifier, base64url without padding`() throws {
        let request = try Self.request()
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8))).base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        #expect(request.codeChallenge == digest)

        let items = Self.queryItems(of: request.url(redirectURI: Self.redirectURI(for: request)))
        #expect(items["code_challenge"] == digest)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == request.state)
        #expect(items["client_id"] == "client-1")
        #expect(items["login_hint"] == "alice@example.com")
        #expect(items["redirect_uri"] == Self.redirectURI(for: request))
        #expect(items["response_type"] == "code")
        #expect(items["scope"] == "xmpp offline_access")
    }

    @Test
    func `Two attempts get different state and verifier`() throws {
        let first = try Self.request()
        let second = try Self.request()
        #expect(first.state != second.state)
        #expect(first.codeVerifier != second.codeVerifier)
    }

    // MARK: - Scope

    struct ScopeCase: Sendable, CustomTestStringConvertible {
        let challenge: String?
        let supported: [String]?
        let expected: String?

        var testDescription: String {
            "challenge \(challenge ?? "none"), listed \(supported.map { "\($0)" } ?? "none")"
        }
    }

    @Test(arguments: [
        ScopeCase(challenge: "xmpp:client:normal openid", supported: ["xmpp", "offline_access"], expected: "xmpp:client:normal openid offline_access"),
        ScopeCase(challenge: "xmpp", supported: nil, expected: "xmpp"),
        ScopeCase(challenge: "xmpp", supported: ["xmpp:client:normal", "xmpp"], expected: "xmpp"),
        ScopeCase(challenge: "xmpp offline_access", supported: ["xmpp", "offline_access"], expected: "xmpp offline_access"),
        ScopeCase(challenge: nil, supported: ["openid", "xmpp", "xmpp:client:normal", "offline_access"], expected: "xmpp:client:normal offline_access"),
        ScopeCase(challenge: nil, supported: ["openid", "xmpp"], expected: "xmpp"),
        ScopeCase(challenge: nil, supported: ["openid", "profile"], expected: "openid"),
        ScopeCase(challenge: nil, supported: ["xmpp", "offline_access", "openid"], expected: "xmpp offline_access"),
        ScopeCase(challenge: nil, supported: ["profile", "offline_access"], expected: nil),
        ScopeCase(challenge: nil, supported: [], expected: nil),
        ScopeCase(challenge: nil, supported: nil, expected: nil)
    ])
    func `Scope selection prefers the challenge's scope, then the narrowest listed XMPP scope`(scope: ScopeCase) {
        #expect(SSOAuthorizationRequest.scope(challengeScope: scope.challenge, scopesSupported: scope.supported) == scope.expected)
    }

    @Test
    func `With no challenge scope and no listed scopes the URL carries no scope parameter`() throws {
        let request = try Self.request(scopes: nil)
        let url = request.url(redirectURI: Self.redirectURI(for: request))
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        #expect(!names.contains("scope"))
        #expect(names.contains("state"))
    }

    // MARK: - Callback validation

    @Test
    func `A callback to the redirect URI with this attempt's state yields its code`() throws {
        let request = try Self.request()
        let redirectURI = Self.redirectURI(for: request)
        let callback = try Self.callback(redirectURI, [("code", "abc"), ("state", request.state)])
        #expect(try request.authorizationCode(from: callback, redirectURI: redirectURI) == "abc")
    }

    @Test
    func `Two issuers get different redirect paths`() {
        let first = SSORedirect.callbackPath(forIssuer: "https://auth.example.com")
        let second = SSORedirect.callbackPath(forIssuer: "https://other.example.com")
        #expect(first != second)
        #expect(first.hasPrefix("/oauth/callback/") && first.count == "/oauth/callback/".count + 16)
    }

    @Test(arguments: [
        "https://127.0.0.1:1234",
        "http://127.0.0.1:1235",
        "http://localhost:1234",
        "http://127.0.0.1:1234/oauth/callback/other",
        "http://127.0.0.1:1234" + SSORedirect.callbackPath(forIssuer: "https://other.example.com")
    ])
    func `A callback to another address is rejected`(base: String) throws {
        let request = try Self.request()
        let path = base.contains("/oauth/") ? "" : request.callbackPath
        let callback = try Self.callback(base + path, [("code", "abc"), ("state", request.state)])
        #expect(throws: SSOError.malformedResponse) {
            try request.authorizationCode(from: callback, redirectURI: Self.redirectURI(for: request))
        }
    }

    @Test
    func `A callback with another state, or none, is rejected`() throws {
        let request = try Self.request()
        let redirectURI = Self.redirectURI(for: request)
        for items in [[("code", "abc"), ("state", "other")], [("code", "abc")], [("code", "abc"), ("state", request.state), ("state", request.state)]] {
            let callback = try Self.callback(redirectURI, items)
            #expect(throws: SSOError.malformedResponse) { try request.authorizationCode(from: callback, redirectURI: redirectURI) }
        }
    }

    @Test
    func `A different iss is rejected even when the metadata does not advertise it`() throws {
        let request = try Self.request(issParameter: false)
        let redirectURI = Self.redirectURI(for: request)
        let callback = try Self.callback(redirectURI, [("code", "abc"), ("state", request.state), ("iss", "https://evil.example.com")])
        #expect(throws: SSOError.malformedResponse) { try request.authorizationCode(from: callback, redirectURI: redirectURI) }
    }

    @Test
    func `A missing iss is rejected while the metadata advertises it`() throws {
        let request = try Self.request(issParameter: true)
        let redirectURI = Self.redirectURI(for: request)
        let missing = try Self.callback(redirectURI, [("code", "abc"), ("state", request.state)])
        #expect(throws: SSOError.malformedResponse) { try request.authorizationCode(from: missing, redirectURI: redirectURI) }

        let matching = try Self.callback(redirectURI, [("code", "abc"), ("state", request.state), ("iss", SSOFixtures.issuer)])
        #expect(try request.authorizationCode(from: matching, redirectURI: redirectURI) == "abc")
    }

    @Test
    func `A callback carrying both code and error is rejected`() throws {
        let request = try Self.request()
        let redirectURI = Self.redirectURI(for: request)
        let callback = try Self.callback(redirectURI, [("code", "abc"), ("error", "access_denied"), ("state", request.state)])
        #expect(throws: SSOError.malformedResponse) { try request.authorizationCode(from: callback, redirectURI: redirectURI) }
    }

    @Test
    func `A callback carrying only an error is a denial`() throws {
        let request = try Self.request()
        let redirectURI = Self.redirectURI(for: request)
        let callback = try Self.callback(redirectURI, [("error", "access_denied"), ("state", request.state)])
        #expect(throws: SSOError.authorizationDenied) { try request.authorizationCode(from: callback, redirectURI: redirectURI) }
    }
}
