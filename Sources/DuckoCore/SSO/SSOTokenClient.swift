import Foundation

/// The token endpoint calls of a public client: the code exchange, the refresh, and revocation (RFC 6749, RFC 7009).
struct SSOTokenClient {
    let http: any SSOHTTPClient
    let credentialStore: any CredentialStore
    var now: @Sendable () -> Date = { Date() }

    /// The grant for an authorization code. A provider that issues no refresh token gives a grant that lasts as long
    /// as its access token.
    func exchange(
        code: String, request: SSOAuthorizationRequest, redirectURI: String, clientIsAdminSupplied: Bool
    ) async throws -> SSOGrant {
        let metadata = request.metadata
        let fields = [
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", request.clientID), ("code_verifier", request.codeVerifier)
        ]
        let tokens = try await requestTokens(
            fields, endpoint: metadata.tokenEndpoint, issuer: metadata.issuer, clientID: request.clientID,
            clientIsAdminSupplied: clientIsAdminSupplied
        )
        return SSOGrant(
            issuer: metadata.issuer, tokenEndpoint: metadata.tokenEndpoint, revocationEndpoint: metadata.revocationEndpoint,
            clientID: request.clientID, clientIsAdminSupplied: clientIsAdminSupplied, accessToken: tokens.accessToken,
            expiresAt: tokens.expiresAt, refreshToken: tokens.refreshToken
        )
    }

    /// `grant` with fresh tokens. A response without a refresh token keeps the one sent (RFC 6749 §6).
    func refresh(_ grant: SSOGrant) async throws -> SSOGrant {
        guard let refreshToken = grant.refreshToken else { throw SSOError.grantInvalid }
        let fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", grant.clientID)]
        let tokens = try await requestTokens(
            fields, endpoint: grant.tokenEndpoint, issuer: grant.issuer, clientID: grant.clientID,
            clientIsAdminSupplied: grant.clientIsAdminSupplied
        )
        var refreshed = grant
        refreshed.accessToken = tokens.accessToken
        refreshed.expiresAt = tokens.expiresAt
        refreshed.refreshToken = tokens.refreshToken ?? refreshToken
        return refreshed
    }

    /// Revokes the grant's longest-lived token where the provider lists a revocation endpoint.
    func revoke(_ grant: SSOGrant) async throws {
        guard let endpoint = grant.revocationEndpoint else { return }
        let (token, hint) = grant.revocableToken
        let request = URLRequest.formPost(to: endpoint, [("token", token), ("token_type_hint", hint), ("client_id", grant.clientID)])
        let (_, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw response.isTemporaryRefusal ? SSOError.providerUnreachable : SSOError.malformedResponse
        }
    }

    /// Forgets an administrator's client that no longer works, so the next sign-in registers a client or, where it
    /// cannot, asks for a client ID again. A client remembered for the issuer since, such as a replacement, is kept.
    private func forgetAdminClient(_ clientID: String, issuer: String) {
        let key = SSOStoreKey.adminClient(issuer: issuer)
        guard let stored = try? credentialStore.loadSecret(for: key), String(data: stored, encoding: .utf8) == clientID else { return }
        try? credentialStore.deleteSecret(for: key)
    }

    private struct Tokens {
        let accessToken: String
        let expiresAt: Date?
        let refreshToken: String?
    }

    private func requestTokens(
        _ fields: [(String, String)], endpoint: URL, issuer: String, clientID: String, clientIsAdminSupplied: Bool
    ) async throws -> Tokens {
        let (json, status) = try await http.sendForJSON(.formPost(to: endpoint, fields))
        guard status == 200 else {
            switch json["error"] as? String {
            case "invalid_grant":
                throw SSOError.grantInvalid
            case "invalid_client":
                if clientIsAdminSupplied {
                    forgetAdminClient(clientID, issuer: issuer)
                }
                throw SSOError.grantInvalid
            default:
                throw SSOError.malformedResponse
            }
        }
        guard (json["token_type"] as? String)?.lowercased() == "bearer",
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw SSOError.malformedResponse
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let refreshToken = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Tokens(accessToken: accessToken, expiresAt: expiresIn.map { now().addingTimeInterval($0) }, refreshToken: refreshToken)
    }
}
