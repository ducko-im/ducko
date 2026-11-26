import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.sso")

/// Runs a sign-in through the browser up to a grant: asks the server where its authorization server is, gets a client
/// for it, and has the user authorize Ducko. The grant it returns is a candidate the caller stores only once the server
/// accepts it.
@MainActor
final class SSOSignInService {
    private let clientFactory: any XMPPClientFactory
    private let credentialStore: any CredentialStore
    private let http: any SSOHTTPClient
    private let browserAuthorizer: any BrowserAuthorizer
    private let tokenClient: SSOTokenClient

    init(
        clientFactory: any XMPPClientFactory, credentialStore: any CredentialStore, http: any SSOHTTPClient,
        tokenClient: SSOTokenClient, browserAuthorizer: any BrowserAuthorizer
    ) {
        self.clientFactory = clientFactory
        self.credentialStore = credentialStore
        self.http = http
        self.tokenClient = tokenClient
        self.browserAuthorizer = browserAuthorizer
    }

    /// A candidate grant for `jid`. `clientID` is an administrator's client for the provider. It overrides a remembered
    /// one, and is remembered itself once a code exchange with it succeeds.
    func authorize(jid: BareJID, host: String?, port: Int?, clientID: String?) async throws -> SSOGrant {
        let challenge = try await probe(jid: jid, host: host, port: port)
        let metadata = try await AuthorizationServerMetadata.fetch(from: challenge.discoveryURL, using: http)
        let (resolvedClientID, isAdminSupplied) = try await client(for: metadata, supplied: clientID)
        let request = SSOAuthorizationRequest(
            metadata: metadata, clientID: resolvedClientID, challengeScope: challenge.scope, loginHint: jid.description
        )
        let (callback, redirectURI) = try await browserAuthorizer.authorize(
            callbackPath: request.callbackPath, makeURL: { request.url(redirectURI: $0) }, expectedState: request.state
        )
        let code = try request.authorizationCode(from: callback, redirectURI: redirectURI)
        let grant = try await tokenClient.exchange(
            code: code, request: request, redirectURI: redirectURI, clientIsAdminSupplied: isAdminSupplied
        )
        if let clientID {
            do {
                try credentialStore.saveSecret(Data(clientID.utf8), for: SSOStoreKey.adminClient(issuer: metadata.issuer))
            } catch {
                log.error("Could not remember the administrator's client ID for the sign-in provider: \(error)")
            }
        }
        return grant
    }

    /// Signs in with an empty token, which a server offering browser sign-in refuses with a challenge naming its
    /// authorization server. A connection or TLS failure is thrown as it is.
    private func probe(jid: BareJID, host: String?, port: Int?) async throws -> BearerChallenge {
        let account = Account(
            id: UUID(), jid: jid, isEnabled: true, connectOnLaunch: false, host: host, port: port, requireTLS: true,
            allowsPLAIN: false, createdAt: Date()
        )
        let (client, _) = await clientFactory.makeClient(
            account: account, secret: .bearerToken(""), resuming: nil, requireTLSOverride: true, omemoService: nil
        )
        do {
            try await client.connect(to: account)
        } catch let XMPPClientError.authenticationFailed(failure) {
            guard let challenge = failure.bearerChallenge else { throw SSOError.serverUnsupported }
            return try BearerChallenge(json: challenge)
        }
        await client.disconnect()
        throw SSOError.serverUnsupported
    }

    /// The supplied client, else one an administrator set up earlier, else a newly registered one.
    private func client(for metadata: AuthorizationServerMetadata, supplied: String?) async throws -> (String, isAdminSupplied: Bool) {
        if let supplied {
            return (supplied, true)
        }
        let stored: Data?
        do {
            stored = try credentialStore.loadSecret(for: SSOStoreKey.adminClient(issuer: metadata.issuer))
        } catch {
            throw SSOError.storeFailed
        }
        if let stored, let clientID = String(data: stored, encoding: .utf8), !clientID.isEmpty {
            return (clientID, true)
        }
        do {
            return try await (SSOClientRegistrar(http: http).register(with: metadata), false)
        } catch SSOError.registrationUnavailable {
            throw SSOError.clientIDRequired(issuer: metadata.issuer)
        }
    }
}
