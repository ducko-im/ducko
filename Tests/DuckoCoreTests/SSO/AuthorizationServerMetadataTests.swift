import Foundation
import Testing
@testable import DuckoCore

struct AuthorizationServerMetadataTests {
    private static func metadataJSON(issuer: String, overriding overrides: [String: Any] = [:]) -> [String: Any] {
        var json = SSOFixtures.metadataJSON()
        json["issuer"] = issuer
        json.merge(overrides) { _, new in new }
        return json
    }

    // MARK: - Issuer derivation

    @Test(arguments: [
        ("https://auth.example.com/.well-known/oauth-authorization-server", ["https://auth.example.com"]),
        ("https://auth.example.com:8443/.well-known/oauth-authorization-server/tenant", ["https://auth.example.com:8443/tenant"]),
        ("https://idp.example.com/realms/xmpp/.well-known/openid-configuration", ["https://idp.example.com/realms/xmpp", "https://idp.example.com/realms/xmpp/"]),
        ("https://idp.example.com/.well-known/openid-configuration", ["https://idp.example.com", "https://idp.example.com/"])
    ])
    func `Each well-known shape implies its issuer`(discovery: String, issuers: [String]) throws {
        #expect(try AuthorizationServerMetadata.expectedIssuers(for: #require(URL(string: discovery))) == issuers)
    }

    @Test(arguments: [
        "http://auth.example.com/.well-known/oauth-authorization-server",
        "https://auth.example.com/.well-known/oauth-authorization-serverx",
        "https://auth.example.com/metadata.json",
        "https://auth.example.com/.well-known/openid-configuration?tenant=a",
        "https://auth.example.com/.well-known/oauth-authorization-server#fragment"
    ])
    func `Any other discovery URL shape fails closed`(discovery: String) throws {
        let url = try #require(URL(string: discovery))
        #expect(throws: SSOError.serverUnsupported) { try AuthorizationServerMetadata.expectedIssuers(for: url) }
    }

    @Test(arguments: ["https://idp.example.com/realms/xmpp", "https://idp.example.com/realms/xmpp/"])
    func `The OIDC shape accepts the issuer with and without a trailing slash`(issuer: String) throws {
        let discovery = try #require(URL(string: "https://idp.example.com/realms/xmpp/.well-known/openid-configuration"))
        let expected = try AuthorizationServerMetadata.expectedIssuers(for: discovery)
        let metadata = try AuthorizationServerMetadata(json: Self.metadataJSON(issuer: issuer), expectedIssuers: expected)
        #expect(metadata.issuer == issuer)
    }

    @Test
    func `The RFC 8414 shape refuses an issuer with an added trailing slash`() throws {
        let expected = try AuthorizationServerMetadata.expectedIssuers(for: SSOFixtures.discoveryURL)
        #expect(throws: SSOError.malformedResponse) {
            try AuthorizationServerMetadata(json: Self.metadataJSON(issuer: SSOFixtures.issuer + "/"), expectedIssuers: expected)
        }
    }

    // MARK: - Validation

    @Test
    func `A mismatched issuer is refused`() {
        #expect(throws: SSOError.malformedResponse) {
            try AuthorizationServerMetadata(
                json: Self.metadataJSON(issuer: "https://evil.example.com"), expectedIssuers: [SSOFixtures.issuer]
            )
        }
    }

    @Test(arguments: ["authorization_endpoint", "token_endpoint", "registration_endpoint", "revocation_endpoint"])
    func `A non-https endpoint is refused`(endpoint: String) {
        let json = Self.metadataJSON(issuer: SSOFixtures.issuer, overriding: [endpoint: "http://auth.example.com/\(endpoint)"])
        #expect(throws: SSOError.malformedResponse) {
            try AuthorizationServerMetadata(json: json, expectedIssuers: [SSOFixtures.issuer])
        }
    }

    @Test
    func `The test server's metadata decodes every field`() throws {
        var json = SSOFixtures.metadataJSON()
        json["authorization_response_iss_parameter_supported"] = true
        let metadata = try AuthorizationServerMetadata(json: json, expectedIssuers: [SSOFixtures.issuer])
        #expect(metadata.authorizationEndpoint == URL(string: "https://auth.example.com/oauth2/authorize"))
        #expect(metadata.tokenEndpoint == URL(string: "https://auth.example.com/oauth2/token"))
        #expect(metadata.registrationEndpoint == URL(string: "https://auth.example.com/oauth2/register"))
        #expect(metadata.revocationEndpoint == URL(string: "https://auth.example.com/oauth2/revoke"))
        #expect(metadata.scopesSupported == ["xmpp", "offline_access", "openid"])
        #expect(metadata.issParameterSupported)
    }

    enum IssSupport: CaseIterable {
        case jsonTrue, jsonFalse, absent, string, one, zero

        /// What the metadata carries, after a round trip through JSON.
        var value: Any? {
            switch self {
            case .jsonTrue: true
            case .jsonFalse: false
            case .absent: nil
            case .string: "true"
            case .one: 1
            case .zero: 0
            }
        }

        /// The decoded flag, or nil when the metadata is refused.
        var decoded: Bool? {
            switch self {
            case .jsonTrue: true
            case .jsonFalse, .absent: false
            case .string, .one, .zero: nil
            }
        }
    }

    @Test(arguments: IssSupport.allCases)
    func `Only a JSON boolean or no value is accepted for iss parameter support`(support: IssSupport) async throws {
        let http = ScriptedSSOHTTPClient { _ in
            var json = SSOFixtures.metadataJSON()
            json["authorization_response_iss_parameter_supported"] = support.value
            return (200, json)
        }
        if let decoded = support.decoded {
            let metadata = try await AuthorizationServerMetadata.fetch(from: SSOFixtures.discoveryURL, using: http)
            #expect(metadata.issParameterSupported == decoded)
        } else {
            await #expect(throws: SSOError.malformedResponse) {
                try await AuthorizationServerMetadata.fetch(from: SSOFixtures.discoveryURL, using: http)
            }
        }
    }

    @Test
    func `Fetching reads the discovery URL and checks the issuer it implies`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, Self.metadataJSON(issuer: "https://evil.example.com")) }
        await #expect(throws: SSOError.malformedResponse) {
            try await AuthorizationServerMetadata.fetch(from: SSOFixtures.discoveryURL, using: http)
        }
        #expect(http.requests.map(\.url) == [SSOFixtures.discoveryURL])
    }

    @Test
    func `Fetching a discovery URL of an unknown shape sends nothing`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (200, SSOFixtures.metadataJSON()) }
        let url = try #require(URL(string: "https://auth.example.com/metadata.json"))
        await #expect(throws: SSOError.serverUnsupported) { try await AuthorizationServerMetadata.fetch(from: url, using: http) }
        #expect(http.requests.isEmpty)
    }
}
