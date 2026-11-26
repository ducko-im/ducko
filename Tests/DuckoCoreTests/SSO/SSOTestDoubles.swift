import Foundation
import os
@testable import DuckoCore

/// Answers the OAuth requests of a browser sign-in from a script and records each one.
final class ScriptedSSOHTTPClient: SSOHTTPClient {
    typealias Reply = (status: Int, body: Any)

    private let respond: @Sendable (URLRequest) async throws -> Reply
    private let recorded = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    /// `respond` returns the status and a JSON object body (or `Data` sent as it is) for each request.
    init(_ respond: @escaping @Sendable (URLRequest) async throws -> Reply) {
        self.respond = respond
    }

    var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    func requests(to path: String) -> [URLRequest] {
        requests.filter { $0.url?.path() == path }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let reply = try await respond(request)
        let data = try (reply.body as? Data) ?? JSONSerialization.data(withJSONObject: reply.body)
        guard let url = request.url else { throw URLError(.badURL) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (data, response)
    }

    /// The test provider at `SSOFixtures.issuer`, which serves its discovery document and answers registration, the
    /// token endpoint and revocation with their closures. The token endpoint's closure gets the request's form fields.
    /// Any other path gets 404.
    static func provider(
        registration: Bool = true,
        register: @escaping @Sendable () -> Reply = { (201, ["client_id": "client-1", "token_endpoint_auth_method": "none"]) },
        token: @escaping @Sendable (_ fields: [String: [String]]) async throws -> Reply = { _ in (200, SSOFixtures.tokenJSON()) },
        revoke: @escaping @Sendable () async -> Reply = { (200, [String: String]()) }
    ) -> ScriptedSSOHTTPClient {
        ScriptedSSOHTTPClient { request in
            switch request.url?.path() {
            case "/.well-known/oauth-authorization-server":
                return (200, SSOFixtures.metadataJSON(registration: registration))
            case "/oauth2/register":
                return register()
            case "/oauth2/token":
                return try await token(SSOFixtures.formFields(request))
            case "/oauth2/revoke":
                return await revoke()
            default:
                return (404, ["error": "not_found"])
            }
        }
    }
}

/// Stands in for the browser: counts its sign-ins and returns the callback `callback` builds for each, by default an
/// approval carrying the code `test-code` and the attempt's state.
final class FakeBrowserAuthorizer: BrowserAuthorizer {
    typealias Callback = @Sendable (_ redirectURI: String, _ authorizationURL: URL, _ state: String) async throws -> URL

    private let callback: Callback
    private let count = OSAllocatedUnfairLock(initialState: 0)

    init(callback: Callback? = nil) {
        self.callback = callback ?? { redirectURI, _, state in
            var components = URLComponents(string: redirectURI)!
            components.queryItems = [URLQueryItem(name: "code", value: "test-code"), URLQueryItem(name: "state", value: state)]
            return components.url!
        }
    }

    var callCount: Int {
        count.withLock { $0 }
    }

    func authorize(
        callbackPath: String, makeURL: @Sendable (_ redirectURI: String) -> URL, expectedState: String
    ) async throws -> (callback: URL, redirectURI: String) {
        count.withLock { $0 += 1 }
        let redirectURI = "http://127.0.0.1:1234\(callbackPath)"
        return try await (callback(redirectURI, makeURL(redirectURI), expectedState), redirectURI)
    }
}

/// Fixtures for the test provider at `issuer`: its metadata, bearer challenge, token responses and grants.
enum SSOFixtures {
    static let issuer = "https://auth.example.com"
    static let discoveryURL = URL(string: "https://auth.example.com/.well-known/oauth-authorization-server")!
    static let challenge = #"{"status":"invalid_token","openid-configuration":"https://auth.example.com/.well-known/oauth-authorization-server"}"#

    static func metadataJSON(registration: Bool = true, revocation: Bool = true, scopes: [String]? = ["xmpp", "offline_access", "openid"]) -> [String: Any] {
        var json: [String: Any] = [
            "issuer": issuer,
            "authorization_endpoint": "https://auth.example.com/oauth2/authorize",
            "token_endpoint": "https://auth.example.com/oauth2/token"
        ]
        if registration { json["registration_endpoint"] = "https://auth.example.com/oauth2/register" }
        if revocation { json["revocation_endpoint"] = "https://auth.example.com/oauth2/revoke" }
        if let scopes { json["scopes_supported"] = scopes }
        return json
    }

    static func tokenJSON(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: Int? = 3600) -> [String: Any] {
        var json: [String: Any] = ["token_type": "Bearer", "access_token": access]
        if let refresh { json["refresh_token"] = refresh }
        if let expiresIn { json["expires_in"] = expiresIn }
        return json
    }

    static func grant(
        access: String = "access-1", refresh: String? = "refresh-1", expiresAt: Date? = Date().addingTimeInterval(3600),
        adminClient: Bool = false
    ) -> SSOGrant {
        SSOGrant(
            issuer: issuer, tokenEndpoint: URL(string: "https://auth.example.com/oauth2/token")!,
            revocationEndpoint: URL(string: "https://auth.example.com/oauth2/revoke")!, clientID: "client-1",
            clientIsAdminSupplied: adminClient, accessToken: access, expiresAt: expiresAt, refreshToken: refresh
        )
    }

    /// The form fields of a recorded POST.
    static func formFields(_ request: URLRequest) -> [String: [String]] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: [String]] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            fields[parts[0], default: []].append(parts.count > 1 ? parts[1] : "")
        }
        return fields
    }
}
