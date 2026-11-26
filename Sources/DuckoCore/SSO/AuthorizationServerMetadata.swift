import Foundation

/// What an authorization server publishes about itself (RFC 8414, OpenID Connect Discovery).
struct AuthorizationServerMetadata: Sendable, Equatable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let revocationEndpoint: URL?
    let scopesSupported: [String]?
    /// Whether the provider puts `iss` into its authorization response (RFC 9207).
    let issParameterSupported: Bool

    static func fetch(from discoveryURL: URL, using http: any SSOHTTPClient) async throws -> Self {
        let expectedIssuers = try expectedIssuers(for: discoveryURL)
        var request = URLRequest(url: discoveryURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (json, status) = try await http.sendForJSON(request)
        guard status == 200 else { throw SSOError.malformedResponse }
        return try Self(json: json, expectedIssuers: expectedIssuers)
    }

    /// Requires the issuer the discovery URL implies, and https for every endpoint.
    init(json: [String: Any], expectedIssuers: [String]) throws(SSOError) {
        guard let issuer = json["issuer"] as? String, expectedIssuers.contains(issuer),
              let authorizationEndpoint = Self.httpsURL(json["authorization_endpoint"]),
              let tokenEndpoint = Self.httpsURL(json["token_endpoint"]) else {
            throw .malformedResponse
        }
        let registrationEndpoint = Self.httpsURL(json["registration_endpoint"])
        let revocationEndpoint = Self.httpsURL(json["revocation_endpoint"])
        guard (json["registration_endpoint"] == nil) == (registrationEndpoint == nil),
              (json["revocation_endpoint"] == nil) == (revocationEndpoint == nil) else {
            throw .malformedResponse
        }
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.scopesSupported = json["scopes_supported"] as? [String]
        let issSupport = json["authorization_response_iss_parameter_supported"]
        guard issSupport == nil || Self.isJSONBool(issSupport) else { throw .malformedResponse }
        self.issParameterSupported = issSupport as? Bool ?? false
    }

    /// The issuers a discovery URL may describe. RFC 8414 §3.1 puts the well-known segment between the host and the
    /// issuer's path. OpenID Connect Discovery §4 appends it to the issuer after removing one trailing `/`, so either
    /// form of that issuer matches. Any other shape fails closed.
    static func expectedIssuers(for discoveryURL: URL) throws(SSOError) -> [String] {
        guard let components = URLComponents(url: discoveryURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil else {
            throw .serverUnsupported
        }
        let origin = "https://\(host)\(components.port.map { ":\($0)" } ?? "")"
        let path = components.percentEncodedPath
        let oauthSegment = "/.well-known/oauth-authorization-server"
        let oidcSegment = "/.well-known/openid-configuration"
        if path.hasPrefix(oauthSegment) {
            let suffix = path.dropFirst(oauthSegment.count)
            guard suffix.isEmpty || suffix.hasPrefix("/") else { throw .serverUnsupported }
            return [origin + suffix]
        }
        if path.hasSuffix(oidcSegment) {
            let prefix = origin + path.dropLast(oidcSegment.count)
            return [prefix, prefix + "/"]
        }
        throw .serverUnsupported
    }

    /// Whether a decoded JSON value is `true` or `false`. `JSONSerialization` hands those over as a boolean `NSNumber`,
    /// which a number or a string never is.
    private static func isJSONBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func httpsURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme?.lowercased() == "https",
              url.host() != nil else { return nil }
        return url
    }
}
