import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

/// Browser sign-ins that another operation on the same address or account overlaps.
@MainActor
struct AccountServiceBrowserSignInOverlapTests {
    @Test(.timeLimit(.minutes(1)), arguments: [SignInMethod.password, .browser])
    func `An add whose address another add takes while the browser is open leaves that account alone`(method: SignInMethod) async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let harness = BrowserSignInHarness(browser: holdingBrowser(entered: entered, release: release))

        let adding = Task { try await harness.service.addBrowserAccount(address: browserJID.description) }
        await entered.wait()
        let otherID = try await harness.addAccount(method)
        await release.signal()

        let error = await #expect(throws: AccountService.AccountServiceError.self) { try await adding.value }
        guard case .duplicateJID = error else {
            Issue.record("Expected duplicateJID, got \(String(describing: error))")
            return
        }
        #expect(try await harness.store.fetchAccounts().map(\.id) == [otherID])
        #expect(harness.service.accounts.map(\.id) == [otherID])
        switch method {
        case .password:
            #expect(harness.credentials.loadPassword(for: browserJID.description) == "secret")
        case .browser:
            #expect(try harness.storedGrant?.refreshToken == storedRefresh)
        }
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(await harness.factory.bearerTokens.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization whose account is taken offline while the candidate is revoked stays offline`() async throws {
        let revoking = AsyncSemaphore()
        let revoked = AsyncSemaphore()
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let provider = makeProvider {
            await revoking.signal()
            await revoked.wait()
        }
        let harness = BrowserSignInHarness(factory: factory, provider: provider)
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await revoking.wait()
        await harness.service.disconnect(accountID: id)
        await revoked.signal()

        #expect(try await boundedFailure(of: signingIn) != nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await factory.bearerTokens == [storedAccess, candidateAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        guard case .disconnected = harness.service.connectionStates[id] else {
            Issue.record("Expected the account to stay disconnected, got \(String(describing: harness.service.connectionStates[id]))")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `A candidate that fails after a connect superseded its attempt leaves that connect's session alone`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess, failure: TestError())

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await gate.entered.wait()
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let session = try #require(await harness.factory.lastTransport)
        await gate.release.signal()

        // The operation ended when the connect took the account over, so it reports a cancellation, not its own failure.
        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await session.isConnected)
        #expect(harness.isConnected(id))
        #expect(await harness.factory.bearerTokens == [candidateAccess, storedAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    enum TakeoverFailure: CaseIterable {
        /// The server refuses the stored token for now.
        case temporaryAuthFailure
        /// The session drops once it is connected.
        case droppedSession
    }

    @Test(.timeLimit(.minutes(1)), arguments: TakeoverFailure.allCases)
    func `A connect that takes the account over from a candidate is retried after a retryable failure`(failure: TakeoverFailure) async throws {
        let storedTries = OSAllocatedUnfairLock(initialState: 0)
        let factory = BrowserServerFactory { token in
            guard token == storedAccess, failure == .temporaryAuthFailure else { return .acceptAlice }
            let attempt = storedTries.withLock { count in
                count += 1
                return count
            }
            return attempt == 1 ? .temporary : .acceptAlice
        }
        let harness = BrowserSignInHarness(factory: factory)
        harness.service.retriesFailedConnects = true
        let id = try await harness.addAccount(.browser)
        let gate = await factory.holdSetup(ofToken: candidateAccess, failure: TestError())

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await gate.entered.wait()
        switch failure {
        case .temporaryAuthFailure:
            await #expect(throws: XMPPClientError.self) { try await harness.service.connect(accountID: id) }
        case .droppedSession:
            try await harness.service.connect(accountID: id)
            try await eventually { harness.isConnected(id) }
            await factory.lastTransport?.simulateDisconnect()
        }

        try await eventually { await factory.bearerTokens == [candidateAccess, storedAccess, storedAccess] && harness.isConnected(id) }
        await gate.release.signal()
        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        #expect(harness.isConnected(id))
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization whose account is taken offline while its rollback ends the candidate's session stays offline`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let setup = await harness.factory.holdSetup(ofToken: candidateAccess)

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await setup.entered.wait()
        let teardown = (entered: AsyncSemaphore(), release: AsyncSemaphore())
        let candidateTransport = try #require(await harness.factory.lastTransport)
        await candidateTransport.installDisconnectGate(entered: teardown.entered, release: teardown.release)
        // The candidate cannot be stored once it connects, so the rollback ends its session.
        harness.credentials.failSecretWrites(saves: true)
        await setup.release.signal()
        await teardown.entered.wait()
        await harness.service.disconnect(accountID: id)
        await teardown.release.signal()

        // The disconnect took the account from the operation, so it reports a cancellation rather than the failed store.
        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.factory.bearerTokens == [storedAccess, candidateAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        guard case .disconnected = harness.service.connectionStates[id] else {
            Issue.record("Expected the account to stay disconnected, got \(String(describing: harness.service.connectionStates[id]))")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose candidate's session drops while it sets up reconnects with the old grant`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let setup = await harness.factory.holdSetup(ofToken: candidateAccess)

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await setup.entered.wait()
        await harness.factory.lastTransport?.simulateDisconnect()
        // The service sees the session end before the candidate's connect returns.
        try await eventually {
            if case .error = harness.service.connectionStates[id] { true } else { false }
        }
        await setup.release.signal()

        // The candidate's own session ended, so the operation failed rather than lost the account to something else.
        let error = try #require(await boundedFailure(of: signingIn))
        #expect(!(error is CancellationError), Comment(rawValue: "\(error)"))
        try await eventually { harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [storedAccess, candidateAccess, storedAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization that fails while a second one connects leaves the second one's session alone`() async throws {
        let provider = makeProvider(candidates: [(candidateAccess, candidateRefresh), ("second-access", "second-refresh")])
        let harness = BrowserSignInHarness(provider: provider)
        let id = try await harness.addAccount(.browser)
        let first = await harness.factory.holdSetup(ofToken: candidateAccess, failure: TestError())
        let firstSigningIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await first.entered.wait()

        let second = await harness.factory.holdSetup(ofToken: "second-access")
        let secondSigningIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await second.entered.wait()
        await first.release.signal()

        let error = try #require(await boundedFailure(of: firstSigningIn))
        #expect(error is CancellationError)
        // The second attempt is still a candidate's, which nothing retries or redirects.
        #expect(harness.service.connectionResources[id]?.candidateAttemptID != nil)
        await second.release.signal()
        try await secondSigningIn.value
        try await eventually { harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [candidateAccess, "second-access"])
        #expect(provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.refreshToken == "second-refresh")
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose account is taken offline while its old session ends never connects the candidate`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let teardown = (entered: AsyncSemaphore(), release: AsyncSemaphore())
        let session = try #require(await harness.factory.lastTransport)
        await session.installDisconnectGate(entered: teardown.entered, release: teardown.release)

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await teardown.entered.wait()
        await harness.service.disconnect(accountID: id)
        await teardown.release.signal()

        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        #expect(await harness.factory.bearerTokens == [storedAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        guard case .disconnected = harness.service.connectionStates[id] else {
            Issue.record("Expected the account to stay disconnected, got \(String(describing: harness.service.connectionStates[id]))")
            return
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization whose account is connected while the candidate is revoked keeps that connect`() async throws {
        let revoking = AsyncSemaphore()
        let revoked = AsyncSemaphore()
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let provider = makeProvider {
            await revoking.signal()
            await revoked.wait()
        }
        let harness = BrowserSignInHarness(factory: factory, provider: provider)
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await revoking.wait()
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        await revoked.signal()

        // The operation lost the account to that connect, so it reports a cancellation rather than its rejection.
        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        try await Task.sleep(for: .milliseconds(100))
        // The rollback leaves the account to that connect rather than connecting it once more.
        #expect(await factory.bearerTokens == [storedAccess, candidateAccess, storedAccess])
        #expect(harness.isConnected(id))
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose account's new certificate is rejected while the browser is open leaves it offline`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let harness = BrowserSignInHarness(browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await entered.wait()
        await harness.service.rejectNewCertificate(for: id)
        await release.signal()

        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await harness.factory.bearerTokens == [storedAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        #expect(!harness.isConnected(id))
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization reconnects an account a retry brought back online while the browser was open`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory, browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        harness.service.reconnectDelay = { _ in .milliseconds(300) }
        await factory.lastTransport?.simulateDisconnect()
        try await eventually { !harness.isConnected(id) && harness.reconnectPending(id) }

        // Offline when the browser opens, and back online through the retry before it returns.
        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await entered.wait()
        try await eventually { harness.isConnected(id) }
        await release.signal()

        #expect(try await boundedFailure(of: signingIn) != nil)
        try await eventually { await factory.bearerTokens.count == 4 && harness.isConnected(id) }
        #expect(await factory.bearerTokens == [storedAccess, storedAccess, candidateAccess, storedAccess])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed re-authorization reconnects an account that was online when the browser opened and dropped since`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory, browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        harness.service.reconnectDelay = { _ in .seconds(30) }
        let session = try #require(await factory.lastTransport)

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await entered.wait()
        // Still offline, with its retry pending, when the browser returns.
        await session.simulateDisconnect()
        try await eventually { !harness.isConnected(id) && harness.reconnectPending(id) }
        await release.signal()

        #expect(try await boundedFailure(of: signingIn) != nil)
        try await eventually { await factory.bearerTokens.count == 3 && harness.isConnected(id) }
        #expect(await factory.bearerTokens == [storedAccess, candidateAccess, storedAccess])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A connect while the browser is open keeps the refresh it started when the re-authorization ends`() async throws {
        let browserEntered = AsyncSemaphore()
        let browserRelease = AsyncSemaphore()
        let refreshEntered = AsyncSemaphore()
        let refreshRelease = AsyncSemaphore()
        let provider = makeProvider(onRefresh: {
            await refreshEntered.signal()
            await refreshRelease.wait()
        })
        let harness = BrowserSignInHarness(provider: provider, browser: holdingBrowser(entered: browserEntered, release: browserRelease))
        let id = try await harness.addAccount(.browser, grant: SSOFixtures.grant(access: storedAccess, refresh: storedRefresh, expiresAt: Date()))

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await browserEntered.wait()
        let connecting = Task { try await harness.service.connect(accountID: id) }
        await refreshEntered.wait()
        await browserRelease.signal()

        let error = try #require(await boundedFailure(of: signingIn))
        #expect(error is CancellationError)
        await refreshRelease.signal()
        try await connecting.value
        try await eventually { harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [refreshedAccess])
        #expect(provider.revokedTokens == [candidateRefresh])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [SignInMethod.password, .browser])
    func `An add whose address another process inserts at the same time fails and removes only its own row`(
        method: SignInMethod
    ) async throws {
        let harness = BrowserSignInHarness()
        try harness.credentials.saveGrant(SSOFixtures.grant(access: storedAccess, refresh: storedRefresh), for: browserJID)
        // Created after this add's row, so only a rule that refuses any second row, not one keeping the earliest, fails here.
        let other = Account(
            id: UUID(), jid: browserJID, isEnabled: true, connectOnLaunch: false, signInMethod: .browser, createdAt: Date().addingTimeInterval(60)
        )
        await harness.store.insertAlongsideNextInsert(other)

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            switch method {
            case .password:
                _ = try await harness.service.createAccount(jidString: browserJID.description)
            case .browser:
                _ = try await harness.service.addBrowserAccount(address: browserJID.description)
            }
        }

        guard case .duplicateJID = error else {
            Issue.record("Expected duplicateJID, got \(String(describing: error))")
            return
        }
        #expect(try await harness.store.fetchAccounts().map(\.id) == [other.id])
        #expect(try harness.storedGrant?.refreshToken == storedRefresh)
        #expect(harness.provider.revokedTokens == (method == .browser ? [candidateRefresh] : []))
        #expect(await harness.factory.bearerTokens.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Two adds of one address at the same time in one app leave exactly one account`() async throws {
        let harness = BrowserSignInHarness()

        let first = Task { try await harness.service.createAccount(jidString: browserJID.description) }
        let second = Task { try await harness.service.createAccount(jidString: browserJID.description) }
        let outcomes = await [first.result, second.result]

        let added = outcomes.compactMap { try? $0.get() }
        #expect(added.count == 1)
        #expect(try await harness.store.fetchAccounts().map(\.id) == added)
        for case let .failure(error) in outcomes {
            guard case .duplicateJID = error as? AccountService.AccountServiceError else {
                Issue.record("Expected duplicateJID, got \(error)")
                continue
            }
        }
    }
}
