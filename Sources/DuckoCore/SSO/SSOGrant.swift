import DuckoXMPP
import Foundation

/// An account's OAuth grant: the tokens and the public client they were issued to.
struct SSOGrant: Codable, Sendable, Equatable {
    /// Kept to forget an administrator's client ID that the provider stops accepting.
    var issuer: String
    var tokenEndpoint: URL
    var revocationEndpoint: URL?
    var clientID: String
    var clientIsAdminSupplied: Bool
    var accessToken: String
    var expiresAt: Date?
    var refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case issuer
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case clientID = "client_id"
        case clientIsAdminSupplied = "client_is_admin_supplied"
        case accessToken = "access_token"
        case expiresAt = "expires_at"
        case refreshToken = "refresh_token"
    }

    /// The token that ends the most when revoked: the refresh token, else the access token.
    var revocableToken: (token: String, hint: String) {
        if let refreshToken { (refreshToken, "refresh_token") } else { (accessToken, "access_token") }
    }
}

/// Names no token, so logging a grant never writes one.
extension SSOGrant: CustomStringConvertible {
    var description: String {
        "SSOGrant(issuer: \(issuer), refreshable: \(refreshToken != nil))"
    }
}

/// Where the credential store keeps browser sign-in state.
enum SSOStoreKey {
    static func grant(for jid: BareJID) -> String {
        "sso-grant:\(jid)"
    }

    static func adminClient(issuer: String) -> String {
        "sso-admin-client:\(issuer)"
    }
}

extension CredentialStore {
    func loadGrant(for jid: BareJID) throws -> SSOGrant? {
        guard let data = try loadSecret(for: SSOStoreKey.grant(for: jid)) else { return nil }
        return try SSOGrant.decoder.decode(SSOGrant.self, from: data)
    }

    func saveGrant(_ grant: SSOGrant, for jid: BareJID) throws {
        try saveSecret(SSOGrant.encoder.encode(grant), for: SSOStoreKey.grant(for: jid))
    }

    func deleteGrant(for jid: BareJID) throws {
        try deleteSecret(for: SSOStoreKey.grant(for: jid))
    }
}

extension SSOGrant {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
