import CryptoKit
import Foundation

/// One attempt at the authorization-code grant with PKCE (RFC 6749 §4.1, RFC 7636): the URL the browser opens, and the
/// check of the callback that ends it.
struct SSOAuthorizationRequest: Sendable {
    let metadata: AuthorizationServerMetadata
    let clientID: String
    let scope: String?
    let loginHint: String
    let state: String
    let codeVerifier: String

    init(metadata: AuthorizationServerMetadata, clientID: String, challengeScope: String?, loginHint: String) {
        self.metadata = metadata
        self.clientID = clientID
        self.scope = Self.scope(challengeScope: challengeScope, scopesSupported: metadata.scopesSupported)
        self.loginHint = loginHint
        self.state = Self.randomToken()
        self.codeVerifier = Self.randomToken()
    }

    var callbackPath: String {
        SSORedirect.callbackPath(forIssuer: metadata.issuer)
    }

    /// The S256 challenge for `codeVerifier`.
    var codeChallenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
    }

    /// The challenge's scope, which RFC 7628 says to request, or else the first of `xmpp:client:normal`, `xmpp` and
    /// `openid` the server lists. `offline_access` is added where listed, so that a refresh token is issued. With
    /// nothing to go on, the server's default applies.
    static func scope(challengeScope: String?, scopesSupported: [String]?) -> String? {
        let supported = scopesSupported ?? []
        let base = challengeScope ?? ["xmpp:client:normal", "xmpp", "openid"].first(where: supported.contains)
        guard let base else { return nil }
        let scopes = base.split(separator: " ").map(String.init)
        guard supported.contains("offline_access"), !scopes.contains("offline_access") else { return base }
        return (scopes + ["offline_access"]).joined(separator: " ")
    }

    func url(redirectURI: String) -> URL {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return metadata.authorizationEndpoint
        }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "login_hint", value: loginHint)
        ]
        if let scope {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = items
        // `+` would read as a space in a form-encoded query.
        let query = components.percentEncodedQuery?.replacing("+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url ?? metadata.authorizationEndpoint
    }

    /// The code from a callback to `redirectURI` that belongs to this attempt. Anything else fails: another address, a
    /// different `state`, both or neither of `code` and `error`, or an `iss` other than the issuer's. A provider that
    /// advertises `iss` must send it (RFC 9207).
    func authorizationCode(from callback: URL, redirectURI: String) throws(SSOError) -> String {
        guard let received = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let expected = URLComponents(string: redirectURI),
              received.scheme?.lowercased() == expected.scheme?.lowercased(),
              received.host?.lowercased() == expected.host?.lowercased(),
              received.port == expected.port,
              received.path == expected.path else {
            throw .malformedResponse
        }
        let items = received.queryItems ?? []
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard value("state") == state else { throw .malformedResponse }
        if let iss = value("iss") {
            guard iss == metadata.issuer else { throw .malformedResponse }
        } else if metadata.issParameterSupported || items.contains(where: { $0.name == "iss" }) {
            throw .malformedResponse
        }
        switch (value("code"), items.contains { $0.name == "error" }) {
        case let (code?, false) where !code.isEmpty:
            return code
        case (nil, true):
            throw .authorizationDenied
        case (.some, _), (nil, false):
            throw .malformedResponse
        }
    }

    private static func randomToken() -> String {
        base64URL(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
    }
}
