import DuckoXMPP
import Foundation

/// Hands out the access token of each browser account's stored grant, refreshing it when it is due. Refreshes run one
/// at a time per account. Another process using the same store may rotate the grant meanwhile, which a failed or late
/// refresh recovers from by reading the store again.
actor SSOTokenProvider {
    /// How long before its expiry a token counts as due.
    static let expiryMargin: TimeInterval = 60

    private let credentialStore: any CredentialStore
    private let tokenClient: SSOTokenClient
    private var inFlight: [UUID: (id: UUID, task: Task<SSOGrant, any Error>)] = [:]

    /// Expiries are read on the token client's clock, which also dates the grants it returns.
    private var now: Date {
        tokenClient.now()
    }

    init(credentialStore: any CredentialStore, tokenClient: SSOTokenClient) {
        self.credentialStore = credentialStore
        self.tokenClient = tokenClient
    }

    /// The token to sign in with, and whether it was refreshed for this call. A token is still used while it has not
    /// expired when its refresh fails at the provider for a reason other than refusing the grant. A refresh whose result
    /// could not be stored fails, since the provider may have retired the stored refresh token.
    func validAccessToken(for account: Account) async throws -> (token: String, refreshedNow: Bool) {
        let grant = try storedGrant(for: account)
        guard isDue(grant) else { return (grant.accessToken, false) }
        guard grant.refreshToken != nil else {
            guard !isExpired(grant) else { throw SSOError.grantInvalid }
            return (grant.accessToken, false)
        }
        do {
            return try await (refresh(grant, account: account).accessToken, true)
        } catch let error as SSOError where ![.grantInvalid, .storeFailed].contains(error) && !isExpired(grant) {
            return (grant.accessToken, false)
        }
    }

    /// Refreshes the stored grant whatever its expiry, for a token the server rejected.
    func forceRefresh(for account: Account) async throws -> String {
        let grant = try storedGrant(for: account)
        guard grant.refreshToken != nil else { throw SSOError.grantInvalid }
        return try await refresh(grant, account: account).accessToken
    }

    /// Ends a refresh in flight for the account, whose result is then never stored.
    func invalidate(accountID: UUID) {
        inFlight.removeValue(forKey: accountID)?.task.cancel()
    }

    // MARK: - Private

    private func storedGrant(for account: Account) throws -> SSOGrant {
        guard let grant = try loadGrant(for: account.jid) else { throw SSOError.grantInvalid }
        return grant
    }

    private func loadGrant(for jid: BareJID) throws(SSOError) -> SSOGrant? {
        do {
            return try credentialStore.loadGrant(for: jid)
        } catch {
            throw .storeFailed
        }
    }

    private func isDue(_ grant: SSOGrant) -> Bool {
        grant.expiresAt.map { $0.timeIntervalSince(now) <= Self.expiryMargin } ?? false
    }

    private func isExpired(_ grant: SSOGrant) -> Bool {
        grant.expiresAt.map { $0 <= now } ?? false
    }

    /// Joins the account's refresh in flight, or starts one.
    private func refresh(_ grant: SSOGrant, account: Account) async throws -> SSOGrant {
        if let running = inFlight[account.id] {
            return try await running.task.value
        }
        let id = UUID()
        let task = Task { try await self.performRefresh(grant, jid: account.jid, retriesReplacement: true) }
        inFlight[account.id] = (id, task)
        defer {
            if inFlight[account.id]?.id == id { inFlight[account.id] = nil }
        }
        return try await task.value
    }

    /// Refreshes `grant` and stores the result only while the store still holds the grant the refresh started from.
    private func performRefresh(_ grant: SSOGrant, jid: BareJID, retriesReplacement: Bool) async throws -> SSOGrant {
        let refreshed: SSOGrant
        do {
            refreshed = try await tokenClient.refresh(grant)
        } catch SSOError.grantInvalid {
            // Another process may have rotated the refresh token this one sent.
            guard retriesReplacement, let current = try loadGrant(for: jid),
                  current.refreshToken != grant.refreshToken else { throw SSOError.grantInvalid }
            return try await usable(current, jid: jid)
        }
        try Task.checkCancellation()
        guard let current = try loadGrant(for: jid) else { throw CancellationError() }
        guard current.refreshToken == grant.refreshToken else {
            guard retriesReplacement else { return current }
            return try await usable(current, jid: jid)
        }
        do {
            try credentialStore.saveGrant(refreshed, for: jid)
        } catch {
            throw SSOError.storeFailed
        }
        return refreshed
    }

    /// A grant another writer stored, refreshed once more when its token is due too.
    private func usable(_ grant: SSOGrant, jid: BareJID) async throws -> SSOGrant {
        guard isDue(grant), grant.refreshToken != nil else { return grant }
        return try await performRefresh(grant, jid: jid, retriesReplacement: false)
    }
}
