import DuckoXMPP
import Foundation
import Logging

private let log = Logger(label: "im.ducko.core.account")

/// How long removing an account or rolling back a sign-in waits for the provider to revoke a grant.
private let revocationDeadline: Duration = .seconds(5)

/// Sign-in through the browser (XEP-0493). A sign-in's candidate grant is used only by the connect attempt of the
/// operation that obtained it, and stored once that attempt signed in. Every later connect takes its token from the
/// stored grant through `SSOTokenProvider`.
public extension AccountService {
    /// Adds an account that signs in through the browser and connects it. `clientID` is a client an administrator set up
    /// for the provider. `afterConnect` runs once the grant is stored. Any failure removes the account again and revokes
    /// the grant.
    func addBrowserAccount(
        address: String, host: String? = nil, port: Int? = nil, clientID: String? = nil,
        afterConnect: ((UUID) async throws -> Void)? = nil
    ) async throws -> UUID {
        guard let jid = BareJID.parse(address) else { throw AccountServiceError.invalidJID(address) }
        if try await store.fetchAccounts().contains(where: { $0.jid == jid }) {
            throw AccountServiceError.duplicateJID(address)
        }
        let candidate = try await ssoSignIn.authorize(jid: jid, host: host, port: port, clientID: clientID)
        let accountID: UUID
        do {
            // Rechecks the address, which another add may have taken while the browser was open.
            accountID = try await createAccount(jidString: address, host: host, port: port, signInMethod: .browser)
        } catch {
            await revoke(candidate)
            throw error
        }
        var committed = false
        do {
            try await runFirstSignIn(accountID: accountID, address: address) {
                let attemptID = try await startConnect(accountID: accountID, candidate: candidate)
                try commit(candidate, jid: jid, accountID: accountID, attemptID: attemptID)
                committed = true
                // A drop from now on reconnects through the stored grant.
                endCandidateAttempt(accountID: accountID, attemptID: attemptID)
                try await afterConnect?(accountID)
            }
        } catch {
            if !committed {
                await revoke(candidate)
            } else if await isStillStored(accountID) {
                // Removing the account ends its grant, so this runs only when that removal failed or the store cannot
                // be read. While the row is stored, no other account with this address can have stored a grant under
                // it.
                await deleteBrowserGrant(accountID: accountID, jid: jid, fallback: candidate)
            }
            throw error
        }
        return accountID
    }

    /// Signs a browser account in through the browser again, replacing its grant once the new one connects. A failure
    /// keeps the old grant, and reconnects the account with it when it was connected. If a requested connect or
    /// disconnect, or the account's removal, takes the account over meanwhile, the sign-in throws `CancellationError`
    /// and leaves the account alone.
    func signInWithBrowser(accountID: UUID, clientID: String? = nil) async throws {
        let account = try accountForBrowserOperation(accountID, requiring: .browser)
        try await replaceGrant(of: account, clientID: clientID)
    }

    /// Switches a password account to sign-in through the browser. The stored password is deleted only once the account
    /// has connected with its grant and stored both the grant and the new method. A failure before that leaves the
    /// password account as it was, reconnected when it was connected. If a requested connect or disconnect, or the
    /// account's removal, takes the account over meanwhile, the switch throws `CancellationError` and does not
    /// reconnect.
    func switchToBrowserSignIn(accountID: UUID, clientID: String? = nil) async throws {
        let account = try accountForBrowserOperation(accountID, requiring: .password)
        try await replaceGrant(of: account, clientID: clientID) {
            do {
                try await store.setSignInMethod(.browser, accountID: accountID)
            } catch {
                do {
                    try credentialStore.deleteGrant(for: account.jid)
                } catch {
                    log.error("Could not delete the grant of a failed switch to browser sign-in: \(error)")
                }
                throw error
            }
        }
        // The switch is stored, so nothing after this undoes or fails it. `accounts` is updated first because connects
        // read the method from it. A password the delete leaves behind is never used by a browser account, and deleting
        // the account deletes it too.
        showSignInMethod(.browser, for: accountID)
        credentialStore.deletePassword(for: account.jid.description)
        do {
            try await loadAccounts()
        } catch {
            log.error("Could not reload the accounts after a switch to browser sign-in: \(error)")
        }
    }

    /// Whether a password sign-in failed where the server offers sign-in through the browser.
    nonisolated static func isBrowserSignInOffered(_ error: any Error) -> Bool {
        switch error as? XMPPClientError {
        case let .authenticationFailed(failure):
            failure.kind == .browserSignInOnly
        case let .plainSignInRefused(browserSignInOffered):
            browserSignInOffered
        case .notConnected, .alreadyConnected, .connectionFailed, .sendFailed, .tlsRequired, .tlsNegotiationFailed, .untrustedCertificate,
             .bindingFailed, .sessionFailed, .unexpectedStreamState, .sessionSetupFailed, .timeout, .streamManagementBusy, .invalidDomain,
             nil:
            false
        }
    }

    /// Hides the alert asking to sign in again. The next connect that finds the grant rejected shows it again.
    func dismissBrowserSignInAlert(for accountID: UUID) {
        browserSignInNeeded.remove(accountID)
    }
}

/// A browser sign-in's hold on an account: the count of requested connects and disconnects it expects, its own
/// included. Any other requested connect or disconnect, or the account's removal, ends the hold, and the account
/// belongs to that from then on. Retries and redirects are not requested and leave the count unchanged.
private struct AccountClaim {
    let accountID: UUID
    var expectedChanges: Int
}

// MARK: - Internal

extension AccountService {
    /// The secret one connect attempt signs in with.
    struct ResolvedSecret {
        /// Where the secret comes from, which decides what a rejection means.
        enum Source {
            /// A password, or a candidate grant's token, which a rejection settles.
            case other
            /// The stored grant's token. One the provider did not just issue is refreshed once when rejected.
            case storedGrant(refreshedNow: Bool)
        }

        let value: SignInSecret
        let source: Source

        var isStoredGrant: Bool {
            switch source {
            case .other: false
            case .storedGrant: true
            }
        }

        /// Whether a rejection is answered with one forced refresh.
        var retriesRejection: Bool {
            switch source {
            case .other: false
            case let .storedGrant(refreshedNow): !refreshedNow
            }
        }
    }

    /// A candidate's token, else the stored grant's for a browser account, else the password.
    func resolveSecret(for account: Account, candidate: SSOGrant?) async throws -> ResolvedSecret {
        if let candidate {
            return ResolvedSecret(value: .bearerToken(candidate.accessToken), source: .other)
        }
        switch account.signInMethod {
        case .browser:
            let (token, refreshedNow) = try await ssoTokens.validAccessToken(for: account)
            return ResolvedSecret(value: .bearerToken(token), source: .storedGrant(refreshedNow: refreshedNow))
        case .password:
            return ResolvedSecret(value: .password(connectionResources[account.id]?.password ?? ""), source: .other)
        }
    }

    /// Unless a browser sign-in's candidate made the failed connect, records that a stored grant the provider no longer
    /// accepts needs the user, and schedules a retry.
    func settleFailedConnect(_ error: any Error, accountID: UUID, candidate: SSOGrant?) {
        guard candidate == nil else { return }
        noteGrantInvalid(error, accountID: accountID)
        // A running retry is the account's reconnect task, and its own failure reschedules it.
        if retriesFailedConnects, Self.isRetryable(error), connectionResources[accountID]?.reconnectTask == nil {
            scheduleReconnect(accountID: accountID)
        }
    }

    /// Records that the account's stored grant needs a new sign-in when `error` says the provider refused it.
    func noteGrantInvalid(_ error: any Error, accountID: UUID) {
        if error as? SSOError == .grantInvalid {
            publishBrowserSignInNeeded(accountID: accountID)
        }
    }

    /// Runs an added account's first sign-in. A failure removes the account again, with what the sign-in stored.
    func runFirstSignIn(accountID: UUID, address: String, _ signIn: () async throws -> Void) async throws {
        accountsInFirstSignIn.insert(accountID)
        defer { accountsInFirstSignIn.remove(accountID) }
        do {
            try await signIn()
            try await loadAccounts()
        } catch {
            await disconnect(accountID: accountID)
            try? await store.unlinkConversations(for: accountID, restoreImportSourceJID: address)
            try? await store.deleteContacts(for: accountID)
            try? await deleteAccount(accountID)
            throw error
        }
    }

    /// Builds the attempt's client, makes it the account's session, and signs it in with `connect`. A rejected
    /// stored-grant token that the provider did not just issue is refreshed once and tried with a new client in the
    /// same attempt. A rejection that is not retried throws `SSOError.grantInvalid`. Throws `CancellationError` once
    /// the attempt is superseded.
    func signInAttempt(
        account: Account, attemptID: UUID, secret: ResolvedSecret, resuming: StreamResumeContext?, requireTLSOverride: Bool? = nil,
        connect: (XMPPClient) async throws -> Void
    ) async throws {
        let accountID = account.id
        let retriesRejection = secret.retriesRejection
        connectionResources[accountID]?.holdsCredentialsRejection = retriesRejection
        connectionResources[accountID]?.heldCredentialsRejection = nil
        let (client, sm) = await buildClient(account: account, secret: secret.value, resuming: resuming, requireTLSOverride: requireTLSOverride)
        guard await attach(client, streamManagement: sm, accountID: accountID, attemptID: attemptID) else {
            await client.disconnect()
            throw CancellationError()
        }
        do {
            try await signIn(with: client, accountID: accountID) { try await connect(client) }
            connectionResources[accountID]?.holdsCredentialsRejection = false
            return
        } catch {
            guard secret.isStoredGrant, Self.isCredentialsRejected(error) else {
                releaseHeldCredentialsRejection(accountID: accountID)
                throw error
            }
            guard retriesRejection else { throw SSOError.grantInvalid }
        }
        let token: String
        do {
            token = try await ssoTokens.forceRefresh(for: account)
        } catch {
            releaseHeldCredentialsRejection(accountID: accountID)
            throw error
        }
        guard connectionResources[accountID]?.attemptID == attemptID else { throw CancellationError() }
        connectionResources[accountID]?.heldCredentialsRejection = nil
        connectionStates[accountID] = .connecting
        onRosterSessionEnded?(accountID, attemptID)
        let (retryClient, retrySM) = await buildClient(
            account: account, secret: .bearerToken(token), resuming: resuming, requireTLSOverride: requireTLSOverride
        )
        // Attaching ends the first client's event consumption, so its rejection stays held until then.
        guard await attach(retryClient, streamManagement: retrySM, accountID: accountID, attemptID: attemptID) else {
            await retryClient.disconnect()
            throw CancellationError()
        }
        connectionResources[accountID]?.holdsCredentialsRejection = false
        connectionResources[accountID]?.heldCredentialsRejection = nil
        do {
            try await signIn(with: retryClient, accountID: accountID) { try await connect(retryClient) }
        } catch where Self.isCredentialsRejected(error) {
            throw SSOError.grantInvalid
        }
    }

    /// Delivers the rejection a stored grant's first client reported, now that no retry follows it.
    private func releaseHeldCredentialsRejection(accountID: UUID) {
        connectionResources[accountID]?.holdsCredentialsRejection = false
        guard let held = connectionResources[accountID]?.heldCredentialsRejection else { return }
        connectionResources[accountID]?.heldCredentialsRejection = nil
        handleEvent(held, accountID: accountID)
    }

    /// Starts a connect the user or a sign-in asked for, with a fresh redirect count and no retry pending. `candidate`
    /// makes the attempt a browser sign-in's one attempt, which nothing retries while it is in flight.
    @discardableResult
    func startConnect(accountID: UUID, candidate: SSOGrant? = nil) async throws -> UUID {
        noteRequestedChange(for: accountID)
        connectionResources[accountID, default: AccountConnectionResources()].redirectCount = 0
        cancelReconnect(for: accountID, resetAttempts: true)
        return try await performConnect(accountID: accountID, candidate: candidate)
    }

    func publishBrowserSignInNeeded(accountID: UUID) {
        guard !accountsInFirstSignIn.contains(accountID) else { return }
        browserSignInNeeded.insert(accountID)
        onBrowserSignInNeeded?(accountID)
    }

    /// Ends the grant of a deleted account: no refresh outlives it, the provider revokes it where it can, and the store
    /// forgets it. `fallback` is revoked instead when the stored grant cannot be read.
    func deleteBrowserGrant(accountID: UUID, jid: BareJID, fallback: SSOGrant? = nil) async {
        await ssoTokens.invalidate(accountID: accountID)
        do {
            if let grant = try credentialStore.loadGrant(for: jid) {
                await revoke(grant)
            }
        } catch {
            // Revoking needs the grant's tokens, but forgetting it does not.
            log.error("Could not read the grant of a deleted account: \(error)")
            if let fallback {
                await revoke(fallback)
            }
        }
        do {
            try credentialStore.deleteGrant(for: jid)
        } catch {
            log.error("Could not delete the grant of a deleted account: \(error)")
        }
    }

    // MARK: - Private

    private func accountForBrowserOperation(_ accountID: UUID, requiring method: SignInMethod) throws -> Account {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountServiceError.accountNotFound(accountID)
        }
        switch (method, account.signInMethod) {
        case (.browser, .browser), (.password, .password):
            return account
        case (.browser, .password):
            throw AccountServiceError.notBrowserAccount(account.jid.description)
        case (.password, .browser):
            throw AccountServiceError.alreadyBrowserAccount(account.jid.description)
        }
    }

    private func isConnected(_ accountID: UUID) -> Bool {
        if case .connected = connectionStates[accountID] { return true }
        return false
    }

    /// Has the user authorize a new grant for an existing account, connects with it, and stores it, then runs
    /// `afterCommit`. A failure until that finishes keeps the account as it was, and reconnects it when it was connected
    /// before the browser opened or just before its session was replaced. Losing the account to a requested connect or
    /// disconnect, or to its removal, only revokes the candidate and throws `CancellationError`, since whatever did that
    /// owns the account now. `afterCommit` must delete the committed grant itself when it fails, since the rollback
    /// only revokes the candidate.
    ///
    /// The replaced grant is not revoked: some providers revoke every token of the client or the user's whole consent
    /// along with it, which would end the new grant too.
    private func replaceGrant(of account: Account, clientID: String?, afterCommit: () async throws -> Void = {}) async throws {
        let accountID = account.id
        var restores = isConnected(accountID)
        var claim = AccountClaim(accountID: accountID, expectedChanges: requestedChanges[accountID, default: 0])
        let candidate = try await ssoSignIn.authorize(jid: account.jid, host: account.host, port: account.port, clientID: clientID)
        do {
            try checkHeld(claim)
            await ssoTokens.invalidate(accountID: accountID)
            try checkHeld(claim)
            // A retry or a redirect may have brought the account back online while the browser was open.
            restores = restores || isConnected(accountID)
            await disconnect(holding: &claim)
            try checkHeld(claim)
            let attemptID = try await startConnect(holding: &claim, candidate: candidate)
            try commit(candidate, jid: account.jid, accountID: accountID, attemptID: attemptID)
            try await afterCommit()
            endCandidateAttempt(accountID: accountID, attemptID: attemptID)
        } catch {
            // The candidate's attempt is left alone here: once the claim is lost it may be another operation's, and the
            // rollback's disconnect ends it otherwise.
            guard holds(claim) else {
                await revoke(candidate)
                throw CancellationError()
            }
            await disconnect(holding: &claim)
            await revoke(candidate)
            guard holds(claim) else { throw CancellationError() }
            if restores {
                try? await connect(accountID: accountID)
            }
            throw error
        }
    }

    private func holds(_ claim: AccountClaim) -> Bool {
        accounts.contains { $0.id == claim.accountID } && requestedChanges[claim.accountID, default: 0] == claim.expectedChanges
    }

    private func checkHeld(_ claim: AccountClaim) throws {
        guard holds(claim) else { throw CancellationError() }
    }

    private func disconnect(holding claim: inout AccountClaim) async {
        claim.expectedChanges += 1
        await disconnect(accountID: claim.accountID)
    }

    private func startConnect(holding claim: inout AccountClaim, candidate: SSOGrant) async throws -> UUID {
        claim.expectedChanges += 1
        return try await startConnect(accountID: claim.accountID, candidate: candidate)
    }

    /// Stores the candidate as the account's grant while its attempt is still the account's current one.
    private func commit(_ candidate: SSOGrant, jid: BareJID, accountID: UUID, attemptID: UUID) throws {
        guard connectionResources[accountID]?.attemptID == attemptID else { throw CancellationError() }
        do {
            try credentialStore.saveGrant(candidate, for: jid)
        } catch {
            throw SSOError.storeFailed
        }
        browserSignInNeeded.remove(accountID)
    }

    /// Whether the store still holds the account. A store that cannot be read counts as holding it.
    private func isStillStored(_ accountID: UUID) async -> Bool {
        guard let stored = try? await store.fetchAccounts() else { return true }
        return stored.contains { $0.id == accountID }
    }

    /// Ends the candidate's attempt, unless another connect has started since.
    private func endCandidateAttempt(accountID: UUID, attemptID: UUID) {
        if connectionResources[accountID]?.candidateAttemptID == attemptID {
            connectionResources[accountID]?.candidateAttemptID = nil
        }
    }

    /// Revokes the grant's refresh token, else its access token, waiting a bounded time. A failure is only logged.
    private func revoke(_ grant: SSOGrant) async {
        let tokenClient = ssoTokenClient
        await runBounded(within: revocationDeadline) {
            do {
                try await tokenClient.revoke(grant)
            } catch {
                log.warning("Could not revoke a browser sign-in grant: \(error.localizedDescription)")
            }
        }
    }
}
