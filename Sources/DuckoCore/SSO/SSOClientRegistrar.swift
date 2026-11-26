import CryptoKit
import Foundation

/// The redirect URIs Ducko registers for an issuer and sends its sign-ins to. Each issuer gets its own callback path
/// (RFC 9700 §4.4.2), so a callback can only complete a sign-in with the issuer it started with.
public enum SSORedirect {
    /// The private-use scheme the app's web authentication session catches.
    public static let customScheme = "im.ducko"

    public static func customRedirectURI(callbackPath: String) -> String {
        "\(customScheme):\(callbackPath)"
    }

    /// The loopback URI, with the listener's port when sent and without it when registered.
    static func loopbackRedirectURI(callbackPath: String, port: UInt16? = nil) -> String {
        "http://127.0.0.1\(port.map { ":\($0)" } ?? "")\(callbackPath)"
    }

    /// `/oauth/callback/<h>`, where `<h>` is the first 16 hex digits of the issuer's SHA-256.
    static func callbackPath(forIssuer issuer: String) -> String {
        let digest = SHA256.hash(data: Data(issuer.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "/oauth/callback/\(hex)"
    }

    /// The redirect URIs Ducko registers, and an administrator allows for its client, at the provider `issuer`: the
    /// private-use URI the app's web authentication session catches, then the loopback URI whose port the provider
    /// ignores when matching (RFC 8252 §7.3).
    public static func redirectURIs(forIssuer issuer: String) -> [String] {
        let path = callbackPath(forIssuer: issuer)
        return [customRedirectURI(callbackPath: path), loopbackRedirectURI(callbackPath: path)]
    }
}

/// Registers Ducko as a public native client with an authorization server (RFC 7591).
struct SSOClientRegistrar {
    let http: any SSOHTTPClient

    /// The client ID the server assigned. Throws `registrationUnavailable` where only an administrator can set up a
    /// client: no registration endpoint, a refused registration, or a client that would need a secret.
    func register(with metadata: AuthorizationServerMetadata) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint else { throw SSOError.registrationUnavailable }
        var body: [String: Any] = [
            "client_name": "Ducko",
            "client_uri": "https://ducko.im",
            "software_id": "im.ducko",
            "application_type": "native",
            "redirect_uris": SSORedirect.redirectURIs(forIssuer: metadata.issuer),
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            body["software_version"] = version
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await http.send(request)
        // A refusal needs no body to be understood, and providers send it as an empty or HTML page too.
        if [401, 403].contains(response.statusCode) { throw SSOError.registrationUnavailable }
        let json = try jsonBody(data, of: response)
        switch response.statusCode {
        case 200, 201:
            // RFC 7591 §2: an omitted method means `client_secret_basic`, which a public client cannot use.
            guard json["token_endpoint_auth_method"] as? String == "none" else { throw SSOError.registrationUnavailable }
            guard let clientID = json["client_id"] as? String, !clientID.isEmpty else { throw SSOError.malformedResponse }
            return clientID
        case 400 where ["invalid_client_metadata", "invalid_redirect_uri"].contains(json["error"] as? String):
            throw SSOError.registrationUnavailable
        default:
            throw SSOError.malformedResponse
        }
    }
}
