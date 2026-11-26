import Foundation

/// The error challenge a server answers an OAUTHBEARER sign-in with (RFC 7628 §3.2.2), naming where its authorization
/// server describes itself (XEP-0493 §2.3.1).
struct BearerChallenge: Sendable, Equatable {
    let status: String?
    /// The scope the server asks the token to carry.
    let scope: String?
    let discoveryURL: URL

    /// Fails closed on a challenge without an https discovery URL.
    init(json: String) throws(SSOError) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let discovery = (object["openid-configuration"] as? String).flatMap(URL.init(string:)),
              discovery.scheme?.lowercased() == "https", discovery.host() != nil else {
            throw .serverUnsupported
        }
        self.status = object["status"] as? String
        self.scope = (object["scope"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.discoveryURL = discovery
    }
}
