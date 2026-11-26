import CryptoKit
import Foundation
import Testing
@testable import DuckoCore

struct SSOClientRegistrarTests {
    private static func metadata(registration: Bool = true) throws -> AuthorizationServerMetadata {
        try AuthorizationServerMetadata(json: SSOFixtures.metadataJSON(registration: registration), expectedIssuers: [SSOFixtures.issuer])
    }

    @Test
    func `Registration posts a public native client with the issuer's two redirect URIs`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (201, ["client_id": "dcr-1", "token_endpoint_auth_method": "none"]) }
        let clientID = try await SSOClientRegistrar(http: http).register(with: Self.metadata())
        #expect(clientID == "dcr-1")

        let request = try #require(http.requests.first)
        #expect(http.requests.count == 1)
        #expect(request.url == URL(string: "https://auth.example.com/oauth2/register"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let httpBody = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: httpBody) as? [String: Any])

        let digest = SHA256.hash(data: Data(SSOFixtures.issuer.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = "/oauth/callback/\(digest.prefix(16))"
        #expect(body["redirect_uris"] as? [String] == ["im.ducko:\(path)", "http://127.0.0.1\(path)"])
        #expect(body["client_name"] as? String == "Ducko")
        #expect(body["client_uri"] as? String == "https://ducko.im")
        #expect(body["software_id"] as? String == "im.ducko")
        #expect(body["application_type"] as? String == "native")
        #expect(body["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(body["response_types"] as? [String] == ["code"])
        #expect(body["token_endpoint_auth_method"] as? String == "none")
    }

    @Test
    func `Metadata without a registration endpoint makes registration unavailable without a request`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (201, ["client_id": "dcr-1", "token_endpoint_auth_method": "none"]) }
        await #expect(throws: SSOError.registrationUnavailable) {
            try await SSOClientRegistrar(http: http).register(with: Self.metadata(registration: false))
        }
        #expect(http.requests.isEmpty)
    }

    @Test(arguments: [
        (403, ["error": "access_denied"]),
        (401, ["error": "invalid_token"]),
        (400, ["error": "invalid_redirect_uri"]),
        (400, ["error": "invalid_client_metadata"]),
        (201, ["client_id": "dcr-1", "token_endpoint_auth_method": "client_secret_basic", "client_secret": "s"]),
        (201, ["client_id": "dcr-1"])
    ] as [(Int, [String: String])])
    func `A refused registration or a confidential client makes registration unavailable`(status: Int, body: [String: String]) async throws {
        let http = ScriptedSSOHTTPClient { _ in (status, body) }
        await #expect(throws: SSOError.registrationUnavailable) {
            try await SSOClientRegistrar(http: http).register(with: Self.metadata())
        }
    }

    @Test(arguments: [401, 403], [Data(), Data("<html><body>Forbidden</body></html>".utf8)])
    func `A registration refused without a JSON body makes registration unavailable`(status: Int, body: Data) async throws {
        let http = ScriptedSSOHTTPClient { _ in (status, body) }
        await #expect(throws: SSOError.registrationUnavailable) {
            try await SSOClientRegistrar(http: http).register(with: Self.metadata())
        }
    }

    @Test(arguments: [429, 503], [Data(#"{"error":"temporarily_unavailable"}"#.utf8), Data("<html><body>Try again later</body></html>".utf8)])
    func `A registration the provider cannot answer now fails as unreachable`(status: Int, body: Data) async throws {
        let http = ScriptedSSOHTTPClient { _ in (status, body) }
        await #expect(throws: SSOError.providerUnreachable) {
            try await SSOClientRegistrar(http: http).register(with: Self.metadata())
        }
    }

    @Test
    func `A registration answer without a client ID is malformed`() async throws {
        let http = ScriptedSSOHTTPClient { _ in (201, ["client_id": "", "token_endpoint_auth_method": "none"]) }
        await #expect(throws: SSOError.malformedResponse) {
            try await SSOClientRegistrar(http: http).register(with: Self.metadata())
        }
    }
}
