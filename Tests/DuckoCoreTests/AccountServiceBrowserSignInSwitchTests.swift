import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

@MainActor
struct AccountServiceBrowserSignInSwitchTests {
    @Test(.timeLimit(.minutes(1)))
    func `A switch deletes the password only once the candidate connected and both writes succeeded`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess)

        let switching = Task { try await harness.service.switchToBrowserSignIn(accountID: id) }
        await gate.entered.wait()
        #expect(harness.credentials.loadPassword(for: browserJID.description) == "secret")
        #expect(try harness.storedGrant == nil)
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .password)
        await gate.release.signal()
        try await switching.value

        #expect(harness.credentials.loadPassword(for: browserJID.description) == nil)
        #expect(try harness.storedGrant?.accessToken == candidateAccess)
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .browser)
        // The same service reads the new method without a reload.
        #expect(harness.service.accounts.first?.signInMethod == .browser)
        #expect(await harness.factory.secrets == [.bearerToken(""), .bearerToken(candidateAccess)])
        #expect(harness.provider.revokedTokens.isEmpty)
        try await eventually { harness.isConnected(id) }
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A rejected candidate in a switch keeps the password account as it was`() async throws {
        let factory = BrowserServerFactory { $0 == candidateAccess ? .reject : .acceptAlice }
        let harness = BrowserSignInHarness(factory: factory)
        let id = try await harness.addAccount(.password)

        let error = try #require(await boundedFailure(of: Task { try await harness.service.switchToBrowserSignIn(accountID: id) }))

        #expect(AccountService.isCredentialsRejected(error))
        #expect(harness.provider.refreshedTokens.isEmpty)
        #expect(harness.service.browserSignInNeeded.isEmpty)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(harness.credentials.loadPassword(for: browserJID.description) == "secret")
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .password)
        #expect(harness.service.accounts.first?.signInMethod == .password)
        #expect(await factory.secrets == [.bearerToken(""), .bearerToken(candidateAccess)])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose method cannot be stored deletes the grant, keeps the password and reconnects with it`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        await harness.store.setSignInMethodWriteError(TestError())

        await #expect(throws: TestError.self) { try await harness.service.switchToBrowserSignIn(accountID: id) }

        try await eventually { harness.isConnected(id) }
        #expect(try harness.storedGrant == nil)
        #expect(harness.credentials.loadPassword(for: browserJID.description) == "secret")
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .password)
        #expect(harness.service.accounts.first?.signInMethod == .password)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(await harness.factory.secrets == [
            .password("secret"), .bearerToken(""), .bearerToken(candidateAccess), .password("secret")
        ])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose password cannot be deleted still leaves a working browser account`() async throws {
        let credentials = MockCredentialStore()
        credentials.keepPasswordsOnDelete()
        let harness = BrowserSignInHarness(credentials: credentials)
        let id = try await harness.addAccount(.password)

        try await harness.service.switchToBrowserSignIn(accountID: id)
        await harness.service.disconnect(accountID: id)
        try await harness.service.connect(accountID: id)

        try await eventually { harness.isConnected(id) }
        #expect(credentials.loadPassword(for: browserJID.description) == "secret")
        #expect(harness.service.accounts.first?.signInMethod == .browser)
        #expect(await harness.factory.bearerTokens == [candidateAccess, candidateAccess])
        #expect(await !harness.factory.secrets.contains { if case .password = $0 { true } else { false } })
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose stored method cannot be read back still succeeds and shows the new method`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        await harness.store.failFetchAccountsOnceAfterSignInMethodWrite(TestError())

        // The method was stored, so the switch succeeds. The service's account list already shows browser sign-in.
        try await harness.service.switchToBrowserSignIn(accountID: id)

        #expect(harness.service.accounts.first { $0.id == id }?.signInMethod == .browser)
        #expect(try harness.storedGrant?.accessToken == candidateAccess)
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .browser)
        #expect(harness.credentials.loadPassword(for: browserJID.description) == nil)
        #expect(harness.provider.revokedTokens.isEmpty)
        try await eventually { harness.isConnected(id) }
        #expect(await harness.factory.secrets == [.password("secret"), .bearerToken(""), .bearerToken(candidateAccess)])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch followed by a dropped stream reconnects through the stored grant, not the password`() async throws {
        let harness = BrowserSignInHarness(provider: makeProvider(candidateExpiresIn: 30))
        let id = try await harness.addAccount(.password)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }

        try await harness.service.switchToBrowserSignIn(accountID: id)
        await harness.factory.lastTransport?.simulateDisconnect()

        try await eventually { await harness.factory.bearerTokens.count == 2 && harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [candidateAccess, refreshedAccess])
        #expect(await harness.factory.secrets.filter { if case .password = $0 { true } else { false } }.count == 1)
        #expect(harness.provider.refreshedTokens == [candidateRefresh])
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose account is deleted while the browser is open revokes the candidate`() async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let harness = BrowserSignInHarness(browser: holdingBrowser(entered: entered, release: release))
        let id = try await harness.addAccount(.password)

        let switching = Task { try await harness.service.switchToBrowserSignIn(accountID: id) }
        await entered.wait()
        try await harness.service.deleteAccount(id)
        await release.signal()

        await #expect(throws: CancellationError.self) { try await switching.value }
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(await harness.factory.bearerTokens.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose candidate session drops while the method is stored does not reconnect with the password`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)
        let write = (entered: AsyncSemaphore(), release: AsyncSemaphore())
        await harness.store.installSignInMethodWriteGate(entered: write.entered, release: write.release)

        let switching = Task { try await harness.service.switchToBrowserSignIn(accountID: id) }
        await write.entered.wait()
        await harness.factory.lastTransport?.simulateDisconnect()
        try await eventually {
            if case .error = harness.service.connectionStates[id] { true } else { false }
        }
        try await Task.sleep(for: .milliseconds(100))
        await write.release.signal()
        try await switching.value

        // Until the method is stored, the candidate's attempt is not retried, so no reconnect sends the password.
        #expect(await harness.factory.secrets == [.bearerToken(""), .bearerToken(candidateAccess)])
        #expect(try harness.storedGrant?.accessToken == candidateAccess)
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .browser)
        #expect(harness.credentials.loadPassword(for: browserJID.description) == nil)
        await harness.service.disconnect(accountID: id)
    }
}
