import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

private func authenticationFailureKind(_ error: (any Error)?) -> AuthenticationFailure.Kind? {
    guard case let .authenticationFailed(failure) = error as? XMPPClientError else { return nil }
    return failure.kind
}

/// Forwards to a `MockPersistenceStore`, except that looking up imported conversations fails while `failsRelink` is
/// set, so `createAccount` throws after it saved the row.
private struct RelinkFailingStore: PersistenceStore {
    let base: MockPersistenceStore
    let failsRelink = OSAllocatedUnfairLock(initialState: true)

    func fetchAccounts() async throws -> [Account] {
        try await base.fetchAccounts()
    }

    func saveAccount(_ account: Account) async throws {
        try await base.saveAccount(account)
    }

    func insertAccount(_ account: Account) async throws -> Bool {
        try await base.insertAccount(account)
    }

    func deleteAccount(_ id: UUID) async throws {
        try await base.deleteAccount(id)
    }

    func setAllowsPLAIN(_ allowsPLAIN: Bool, accountID: UUID) async throws {
        try await base.setAllowsPLAIN(allowsPLAIN, accountID: accountID)
    }

    func setSignInMethod(_ method: SignInMethod, accountID: UUID) async throws {
        try await base.setSignInMethod(method, accountID: accountID)
    }

    func fetchChannelSearchLimits(accountID: UUID) async throws -> [String: ChannelSearchLimit] {
        try await base.fetchChannelSearchLimits(accountID: accountID)
    }

    func updateChannelSearchLimits(accountID: UUID, _ change: @Sendable (inout [String: ChannelSearchLimit]) -> Void) async throws {
        try await base.updateChannelSearchLimits(accountID: accountID, change)
    }

    func fetchContacts(for accountID: UUID) async throws -> [Contact] {
        try await base.fetchContacts(for: accountID)
    }

    func upsertContact(_ contact: Contact) async throws {
        try await base.upsertContact(contact)
    }

    func deleteContact(_ id: UUID) async throws {
        try await base.deleteContact(id)
    }

    func applyRosterMutation(_ mutation: RosterMutation) async throws -> [Contact] {
        try await base.applyRosterMutation(mutation)
    }

    func updateContactIfExists(_ id: UUID, accountID: UUID, update: ContactMetadataUpdate) async throws -> Bool {
        try await base.updateContactIfExists(id, accountID: accountID, update: update)
    }

    func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        try await base.fetchConversations(for: accountID)
    }

    func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) async throws -> Conversation? {
        try await base.fetchConversation(jid: jid, type: type, accountID: accountID, importSourceJID: importSourceJID)
    }

    func fetchConversations(importSourceJID: String) async throws -> [Conversation] {
        if failsRelink.withLock({ $0 }) { throw TestError() }
        return try await base.fetchConversations(importSourceJID: importSourceJID)
    }

    func upsertConversation(_ conversation: Conversation) async throws {
        try await base.upsertConversation(conversation)
    }

    func updateConversation(_ conversationID: UUID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation? {
        try await base.updateConversation(conversationID, change)
    }

    func fetchAllConversations() async throws -> [Conversation] {
        try await base.fetchAllConversations()
    }

    func markConversationRead(_ conversationID: UUID) async throws {
        try await base.markConversationRead(conversationID)
    }

    func deleteConversation(_ conversationID: UUID) async throws {
        try await base.deleteConversation(conversationID)
    }

    func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) async throws {
        try await base.unlinkConversations(for: accountID, restoreImportSourceJID: restoreImportSourceJID)
    }

    func deleteConversations(for accountID: UUID) async throws {
        try await base.deleteConversations(for: accountID)
    }

    func deleteContacts(for accountID: UUID) async throws {
        try await base.deleteContacts(for: accountID)
    }

    func fetchLinkPreview(for url: String) async throws -> LinkPreview? {
        try await base.fetchLinkPreview(for: url)
    }

    func upsertLinkPreview(_ preview: LinkPreview) async throws {
        try await base.upsertLinkPreview(preview)
    }
}

@MainActor
struct AccountServiceBrowserSignInTests {
    // MARK: - Connecting

    @Test(.timeLimit(.minutes(1)))
    func `A browser account connects and follows a redirect with its stored grant's token`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)

        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let original = try #require(await harness.factory.lastTransport)
        await original.simulateReceive(
            "<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>"
        )
        try await eventually { await harness.factory.requests.count == 2 && harness.isConnected(id) }

        let requests = await harness.factory.requests
        #expect(requests.map(\.secret) == [.bearerToken(storedAccess), .bearerToken(storedAccess)])
        #expect(requests[1].requireTLS == true)
        #expect(await requests[1].transport.connectedHost == "redirect.example.com")
        await harness.service.disconnect(accountID: id)
    }

    // MARK: - Adding

    @Test(.timeLimit(.minutes(1)))
    func `Adding an account connects with the candidate's token and stores the grant before afterConnect`() async throws {
        let harness = BrowserSignInHarness()
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess)
        let credentials = harness.credentials
        let grantSeenByAfterConnect = OSAllocatedUnfairLock<String?>(initialState: nil)

        let adding = Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in
                let grant = try credentials.loadGrant(for: browserJID)
                grantSeenByAfterConnect.withLock { $0 = grant?.accessToken }
            }
        }
        await gate.entered.wait()
        #expect(try harness.storedGrant == nil)
        await gate.release.signal()
        let id = try await adding.value

        #expect(await harness.factory.secrets == [.bearerToken(""), .bearerToken(candidateAccess)])
        #expect(grantSeenByAfterConnect.withLock { $0 } == candidateAccess)
        #expect(try harness.storedGrant?.refreshToken == candidateRefresh)
        #expect(harness.service.accounts.first { $0.id == id }?.signInMethod == .browser)
        try await eventually { harness.isConnected(id) }
        #expect(harness.provider.revokedTokens.isEmpty)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Adding an address that already has an account opens no browser`() async throws {
        let harness = BrowserSignInHarness()
        _ = try await harness.addAccount(.password)

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            _ = try await harness.service.addBrowserAccount(address: browserJID.description)
        }

        guard case .duplicateJID = error else {
            Issue.record("Expected duplicateJID, got \(String(describing: error))")
            return
        }
        #expect(harness.browser.callCount == 0)
        #expect(await harness.factory.requests.isEmpty)
    }

    enum AddFailure: CaseIterable {
        case accountMismatch
        case afterConnect
        case rejectedCandidate
    }

    @Test(.timeLimit(.minutes(1)), arguments: AddFailure.allCases)
    func `A failed add revokes the candidate and stores no grant or account`(failure: AddFailure) async throws {
        let factory = BrowserServerFactory { token in
            switch failure {
            case .accountMismatch: .accept(bound: "mallory@example.com/ducko")
            case .afterConnect: .acceptAlice
            case .rejectedCandidate: token == candidateAccess ? .reject : .acceptAlice
            }
        }
        let harness = BrowserSignInHarness(factory: factory)

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in
                if failure == .afterConnect { throw TestError() }
            }
        }))

        switch failure {
        case .accountMismatch: #expect(authenticationFailureKind(error) == .accountMismatch)
        case .afterConnect: #expect(error is TestError)
        case .rejectedCandidate: #expect(authenticationFailureKind(error) == .credentialsRejected)
        }
        // Every failure revokes the candidate once. After a failed afterConnect, the candidate is already the committed
        // grant.
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(try await harness.store.fetchAccounts().isEmpty)
        #expect(harness.service.accounts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `An add whose account creation fails after saving the row leaves no row behind`() async throws {
        let base = MockPersistenceStore()
        let persistence = RelinkFailingStore(base: base)
        let harness = BrowserSignInHarness(store: base, persistence: persistence)

        await #expect(throws: TestError.self) {
            _ = try await harness.service.addBrowserAccount(address: browserJID.description)
        }
        #expect(try await base.fetchAccounts().isEmpty)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)

        persistence.failsRelink.withLock { $0 = false }
        let id = try await harness.service.addBrowserAccount(address: browserJID.description)
        #expect(try await base.fetchAccounts().map(\.id) == [id])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A stream dropped during afterConnect reconnects through the stored grant`() async throws {
        // The candidate expires within the refresh margin, so a reconnect through the stored grant refreshes it first.
        let harness = BrowserSignInHarness(provider: makeProvider(candidateExpiresIn: 30))
        let factory = harness.factory
        let service = harness.service

        let id = try await service.addBrowserAccount(address: browserJID.description) { _ in
            await factory.lastTransport?.simulateDisconnect()
            try await eventually { await factory.bearerTokens.contains(refreshedAccess) && harness.isConnected(service.accounts[0].id) }
        }

        #expect(await factory.bearerTokens == [candidateAccess, refreshedAccess])
        #expect(await !factory.secrets.contains { if case .password = $0 { true } else { false } })
        #expect(harness.provider.refreshedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == refreshedAccess)
        #expect(service.browserSignInNeeded.isEmpty)
        try await eventually { harness.isConnected(id) }
        await service.disconnect(accountID: id)
    }

    enum CandidateDrop: CaseIterable {
        case connectionLost
        case retryableStreamError
        case redirect
        case transientSetupFailure
    }

    @Test(.timeLimit(.minutes(1)), arguments: CandidateDrop.allCases)
    func `A drop while the candidate signs in starts no reconnect`(drop: CandidateDrop) async throws {
        let harness = BrowserSignInHarness()
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess)
        let adding = Task { try await harness.service.addBrowserAccount(address: browserJID.description) }
        await gate.entered.wait()
        let id = try #require(harness.service.accounts.first?.id)
        let transport = try #require(await harness.factory.lastTransport)
        let candidateClient = harness.service.client(for: id)

        switch drop {
        case .connectionLost:
            await transport.simulateDisconnect()
        case .retryableStreamError:
            await transport.simulateReceive("<error><system-shutdown xmlns='urn:ietf:params:xml:ns:xmpp-streams'/></error>")
        case .redirect:
            await transport.simulateReceive(
                "<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>"
            )
        case .transientSetupFailure:
            // The event a session whose setup timed out ends with, which a held setup cannot produce by itself.
            harness.service.handleEvent(.disconnected(.setupFailed(XMPPClientError.timeout)), accountID: id)
        }
        try await eventually { harness.service.client(for: id) == nil }
        #expect(!harness.reconnectPending(id))
        await gate.release.signal()

        #expect(try await boundedFailure(of: adding) != nil)
        await candidateClient?.disconnect()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.factory.requests.count == 2)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try await harness.store.fetchAccounts().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A retryable failure of the candidate's attempt schedules no retry`() async throws {
        let factory = BrowserServerFactory { $0 == candidateAccess ? .temporary : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory)
        harness.service.retriesFailedConnects = true
        var pendingAtTeardown: [Bool] = []
        harness.service.onRequestedDisconnect = { pendingAtTeardown.append(harness.reconnectPending($0)) }

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description)
        }))

        #expect(authenticationFailureKind(error) == .temporary)
        // The rollback's teardown is the first point after the failed attempt settled, and it cancels any retry.
        #expect(pendingAtTeardown.first == false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await factory.requests.count == 2)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try await harness.store.fetchAccounts().isEmpty)
    }

    // MARK: - Operation Preconditions

    @Test(.timeLimit(.minutes(1)))
    func `Signing a password account in with the browser fails before the browser opens`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            try await harness.service.signInWithBrowser(accountID: id)
        }

        guard case .notBrowserAccount = error else {
            Issue.record("Expected notBrowserAccount, got \(String(describing: error))")
            return
        }
        #expect(harness.browser.callCount == 0)
        #expect(await harness.factory.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Switching a browser account to browser sign-in fails before the browser opens`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            try await harness.service.switchToBrowserSignIn(accountID: id)
        }

        guard case .alreadyBrowserAccount = error else {
            Issue.record("Expected alreadyBrowserAccount, got \(String(describing: error))")
            return
        }
        #expect(harness.browser.callCount == 0)
        #expect(await harness.factory.requests.isEmpty)
    }

    // MARK: - Re-authorization

    @Test(.timeLimit(.minutes(1)))
    func `A rejected candidate in a re-authorization neither refreshes nor changes the sign-in need`() async throws {
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.browser)
        harness.service.browserSignInNeeded.insert(id)
        var hookCalls = 0
        harness.service.onBrowserSignInNeeded = { _ in hookCalls += 1 }

        let error = try #require(await boundedFailure(of: Task { try await harness.service.signInWithBrowser(accountID: id) }))

        #expect(authenticationFailureKind(error) == .credentialsRejected)
        #expect(harness.provider.refreshedTokens.isEmpty)
        #expect(harness.service.browserSignInNeeded == [id])
        #expect(hookCalls == 0)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        #expect(await harness.factory.bearerTokens == [candidateAccess])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization of a connected account reconnects it with the stored grant`() async throws {
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        #expect(try await boundedFailure(of: Task { try await harness.service.signInWithBrowser(accountID: id) }) != nil)

        try await eventually { harness.isConnected(id) }
        #expect(await factory.bearerTokens == [storedAccess, candidateAccess, storedAccess])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A grant that cannot be stored after the candidate connected disconnects that session`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        harness.credentials.failSecretWrites(saves: true)

        await #expect(throws: SSOError.storeFailed) { try await harness.service.signInWithBrowser(accountID: id) }

        let candidateTransport = try #require(await harness.factory.lastTransport)
        #expect(await !candidateTransport.isConnected)
        #expect(harness.service.client(for: id) == nil)
        #expect(!harness.isConnected(id))
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization followed by a dropped stream reconnects through the stored grant`() async throws {
        let harness = BrowserSignInHarness(provider: makeProvider(candidateExpiresIn: 30))
        let id = try await harness.addAccount(.browser)
        harness.service.browserSignInNeeded.insert(id)

        try await harness.service.signInWithBrowser(accountID: id)
        #expect(harness.service.browserSignInNeeded.isEmpty)
        await harness.factory.lastTransport?.simulateDisconnect()

        try await eventually { await harness.factory.bearerTokens.count == 2 && harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [candidateAccess, refreshedAccess])
        #expect(harness.provider.refreshedTokens == [candidateRefresh])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose account is deleted while the browser is open revokes the candidate`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let harness = BrowserSignInHarness(browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.browser)

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await entered.wait()
        try await harness.service.deleteAccount(id)
        await release.signal()

        await #expect(throws: CancellationError.self) { try await signingIn.value }
        #expect(harness.provider.revokedTokens == [storedRefresh, candidateRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(await harness.factory.bearerTokens.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose account is taken offline while the browser is open leaves it offline`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let harness = BrowserSignInHarness(browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await entered.wait()
        await harness.service.disconnect(accountID: id)
        await release.signal()

        await #expect(throws: CancellationError.self) { try await signingIn.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(await harness.factory.bearerTokens == [storedAccess])
        guard case .disconnected = harness.service.connectionStates[id] else {
            Issue.record("Expected the account to stay disconnected, got \(String(describing: harness.service.connectionStates[id]))")
            return
        }
        #expect(try harness.storedGrant?.accessToken == storedAccess)
    }

    // MARK: - Stored Grant Sign-In

    @Test(.timeLimit(.minutes(1)))
    func `A provider that cannot be reached schedules a retry and opens no browser`() async throws {
        let harness = BrowserSignInHarness(provider: makeProvider(refresh: .unreachable))
        harness.service.retriesFailedConnects = true
        let id = try await harness.addAccount(.browser, grant: SSOFixtures.grant(
            access: storedAccess, refresh: storedRefresh, expiresAt: Date().addingTimeInterval(-60)
        ))

        await #expect(throws: SSOError.providerUnreachable) { try await harness.service.connect(accountID: id) }

        try await eventually { harness.provider.refreshedTokens.count >= 2 }
        #expect(harness.browser.callCount == 0)
        #expect(await harness.factory.requests.isEmpty)
        #expect(harness.service.browserSignInNeeded.isEmpty)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A grant the provider no longer accepts asks for a browser sign-in and is not retried`() async throws {
        let harness = BrowserSignInHarness(provider: makeProvider(refresh: .invalidGrant))
        harness.service.retriesFailedConnects = true
        let id = try await harness.addAccount(.browser, grant: SSOFixtures.grant(
            access: storedAccess, refresh: storedRefresh, expiresAt: Date().addingTimeInterval(-60)
        ))
        var needed: [UUID] = []
        harness.service.onBrowserSignInNeeded = { needed.append($0) }

        await #expect(throws: SSOError.grantInvalid) { try await harness.service.connect(accountID: id) }
        try await Task.sleep(for: .milliseconds(100))

        #expect(harness.service.browserSignInNeeded == [id])
        #expect(needed == [id])
        #expect(!harness.reconnectPending(id))
        #expect(harness.provider.refreshedTokens == [storedRefresh])
        #expect(await harness.factory.requests.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Dismissing the alert removes the account from those needing a browser sign-in`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        harness.service.browserSignInNeeded.insert(id)

        harness.service.dismissBrowserSignInAlert(for: id)

        #expect(harness.service.browserSignInNeeded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A rejected stored token is refreshed once without forwarding the first rejection`() async throws {
        let factory = BrowserServerFactory { $0 == storedAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.browser)
        var failures: [AuthenticationFailure] = []
        harness.service.onEvent = { event, _ in
            if case let .authenticationFailed(failure) = event { failures.append(failure) }
        }

        try await harness.service.connect(accountID: id)

        try await eventually { harness.isConnected(id) }
        #expect(failures.isEmpty)
        #expect(await factory.bearerTokens == [storedAccess, refreshedAccess])
        #expect(harness.provider.refreshedTokens == [storedRefresh])
        #expect(try harness.storedGrant?.accessToken == refreshedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A refreshed token that is rejected too makes the grant invalid without another refresh`() async throws {
        let factory = BrowserServerFactory { _ in .reject }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.browser)

        await #expect(throws: SSOError.grantInvalid) { try await harness.service.connect(accountID: id) }

        #expect(await factory.bearerTokens == [storedAccess, refreshedAccess])
        #expect(harness.provider.refreshedTokens == [storedRefresh])
        #expect(harness.service.browserSignInNeeded == [id])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A temporary failure of a stored token does not refresh it`() async throws {
        let factory = BrowserServerFactory { _ in .temporary }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.browser)

        let error = try #require(await boundedFailure(of: Task { try await harness.service.connect(accountID: id) }))

        #expect(authenticationFailureKind(error) == .temporary)
        #expect(harness.provider.refreshedTokens.isEmpty)
        #expect(await factory.bearerTokens == [storedAccess])
        #expect(harness.service.browserSignInNeeded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [RefreshReply.invalidGrant, .unreachable])
    func `A rejected stored token whose forced refresh fails reports the rejection once`(refresh: RefreshReply) async throws {
        let factory = BrowserServerFactory { $0 == storedAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory, provider: makeProvider(refresh: refresh))
        let id = try await harness.addAccount(.browser)
        var kinds: [AuthenticationFailure.Kind] = []
        harness.service.onEvent = { event, _ in
            if case let .authenticationFailed(failure) = event { kinds.append(failure.kind) }
        }

        let error = try #require(await boundedFailure(of: Task { try await harness.service.connect(accountID: id) }))

        #expect(error as? SSOError == (refresh == .invalidGrant ? .grantInvalid : .providerUnreachable))
        try await eventually { !kinds.isEmpty }
        // Long enough for a second delivery to arrive.
        try await Task.sleep(for: .milliseconds(100))
        #expect(kinds == [.credentialsRejected])
        #expect(harness.provider.refreshedTokens == [storedRefresh])
        #expect(await factory.bearerTokens == [storedAccess])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A redirect whose stored grant the provider no longer accepts asks for a browser sign-in`() async throws {
        let rejecting = OSAllocatedUnfairLock(initialState: false)
        let factory = BrowserServerFactory { _ in rejecting.withLock { $0 } ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory, provider: makeProvider(refresh: .invalidGrant))
        let id = try await harness.addAccount(.browser)
        var needed: [UUID] = []
        harness.service.onBrowserSignInNeeded = { needed.append($0) }
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        rejecting.withLock { $0 = true }
        await harness.factory.lastTransport?.simulateReceive(
            "<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>"
        )

        try await eventually { !needed.isEmpty }
        #expect(needed == [id])
        #expect(harness.service.browserSignInNeeded == [id])
        // Long enough for a retry to start if one were scheduled.
        try await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.refreshedTokens == [storedRefresh])
        #expect(await factory.bearerTokens == [storedAccess, storedAccess])
        guard case let .error(message) = harness.service.connectionStates[id] else {
            Issue.record("Expected an error state, got \(String(describing: harness.service.connectionStates[id]))")
            return
        }
        #expect(message == SSOError.grantInvalid.localizedDescription)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [65536, 0, -1])
    func `A stored port outside 1 to 65535 fails a connect and a sign-in probe before they dial`(port: Int) async throws {
        let harness = BrowserSignInHarness()
        let account = Account(
            id: UUID(), jid: browserJID, isEnabled: true, connectOnLaunch: false, host: "127.0.0.1", port: port, createdAt: Date()
        )
        try await harness.store.saveAccount(account)
        harness.credentials.savePassword("secret", for: browserJID.description)
        try await harness.service.loadAccounts()

        let connectError = await #expect(throws: AccountService.AccountServiceError.self) {
            try await harness.service.connect(accountID: account.id)
        }
        let addError = await #expect(throws: AccountService.AccountServiceError.self) {
            _ = try await harness.service.addBrowserAccount(address: "bob@example.com", host: "127.0.0.1", port: port)
        }

        for error in [connectError, addError] {
            guard case .invalidPort(port) = error else {
                Issue.record("Expected invalidPort(\(port)), got \(String(describing: error))")
                continue
            }
        }
        #expect(harness.browser.callCount == 0)
        for request in await harness.factory.requests {
            #expect(await request.transport.connectedHost == nil)
        }
    }

    // MARK: - Account Management

    @Test(.timeLimit(.minutes(1)))
    func `Deleting an account revokes its grant before deleting it`() async throws {
        let credentials = MockCredentialStore()
        let storedAtRevocation = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let provider = makeProvider {
            let stored = (try? credentials.loadGrant(for: browserJID)) != nil
            storedAtRevocation.withLock { $0.append(stored) }
        }
        let harness = BrowserSignInHarness(credentials: credentials, provider: provider)
        let id = try await harness.addAccount(.browser)
        harness.service.browserSignInNeeded.insert(id)

        try await harness.service.deleteAccount(id)

        #expect(harness.provider.revokedTokens == [storedRefresh])
        #expect(storedAtRevocation.withLock { $0 } == [true])
        #expect(try harness.storedGrant == nil)
        #expect(harness.service.browserSignInNeeded.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Deleting an account whose stored grant cannot be decoded still deletes it`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        let key = SSOStoreKey.grant(for: browserJID)
        try harness.credentials.saveSecret(Data("not a grant".utf8), for: key)

        try await harness.service.deleteAccount(id)

        #expect(try harness.credentials.loadSecret(for: key) == nil)
        #expect(harness.provider.revokedTokens.isEmpty)
        #expect(harness.service.accounts.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Changing a browser account's password sends it and stores no password`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let transport = try #require(await harness.factory.lastTransport)

        try await harness.service.changePassword(accountID: id, newPassword: "new-secret")

        let change = try await sentStanza(on: transport, containing: XMPPNamespaces.register)
        #expect(change.contains("new-secret"))
        #expect(harness.credentials.loadPassword(for: browserJID.description) == nil)
        #expect(harness.service.connectionResources[id]?.password == nil)
        await harness.service.disconnect(accountID: id)
    }

    enum OfferedErrorShape: CaseIterable {
        case browserSignInOnly
        case credentialsRejected
        case plainRefusedWithBrowserOffer
        case plainRefusedWithoutBrowserOffer
        case timeout
        case unrelated

        var error: any Error {
            switch self {
            case .browserSignInOnly:
                XMPPClientError.authenticationFailed(AuthenticationFailure(kind: .browserSignInOnly, message: "browser"))
            case .credentialsRejected:
                XMPPClientError.authenticationFailed(AuthenticationFailure(kind: .credentialsRejected, message: "rejected"))
            case .plainRefusedWithBrowserOffer:
                XMPPClientError.plainSignInRefused(browserSignInOffered: true)
            case .plainRefusedWithoutBrowserOffer:
                XMPPClientError.plainSignInRefused(browserSignInOffered: false)
            case .timeout:
                XMPPClientError.timeout
            case .unrelated:
                TestError()
            }
        }

        var offered: Bool {
            switch self {
            case .browserSignInOnly, .plainRefusedWithBrowserOffer: true
            case .credentialsRejected, .plainRefusedWithoutBrowserOffer, .timeout, .unrelated: false
            }
        }
    }

    @Test(arguments: OfferedErrorShape.allCases)
    func `Browser sign-in is offered only for a browser-only server or a refused PLAIN with an offer`(shape: OfferedErrorShape) {
        #expect(AccountService.isBrowserSignInOffered(shape.error) == shape.offered)
    }
}
