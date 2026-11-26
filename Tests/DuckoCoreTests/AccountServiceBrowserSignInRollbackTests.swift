import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private struct TestError: Error {}

/// What a browser sign-in that fails after its candidate signed in, or an account removal, leaves behind.
@MainActor
struct AccountServiceBrowserSignInRollbackTests {
    /// Whether `error` is a session setup that failed with `TestError`.
    private func isSetupFailure(_ error: (any Error)?) -> Bool {
        guard case let .sessionSetupFailed(cause) = error as? XMPPClientError else { return false }
        return cause is TestError
    }

    @Test(.timeLimit(.minutes(1)))
    func `A re-authorization whose candidate's session setup fails reconnects the account with the stored grant`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.browser)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess, failure: TestError())

        let signingIn = Task { try await harness.service.signInWithBrowser(accountID: id) }
        await gate.entered.wait()
        await gate.release.signal()

        let error = try #require(await boundedFailure(of: signingIn))
        #expect(isSetupFailure(error), Comment(rawValue: "\(error)"))
        try await eventually { harness.isConnected(id) }
        #expect(await harness.factory.bearerTokens == [storedAccess, candidateAccess, storedAccess])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant?.accessToken == storedAccess)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A switch whose candidate's session setup fails reconnects the account with its password`() async throws {
        let harness = BrowserSignInHarness()
        let id = try await harness.addAccount(.password)
        try await harness.service.connect(accountID: id)
        try await eventually { harness.isConnected(id) }
        let gate = await harness.factory.holdSetup(ofToken: candidateAccess, failure: TestError())

        let switching = Task { try await harness.service.switchToBrowserSignIn(accountID: id) }
        await gate.entered.wait()
        await gate.release.signal()

        let error = try #require(await boundedFailure(of: switching))
        #expect(isSetupFailure(error), Comment(rawValue: "\(error)"))
        try await eventually { harness.isConnected(id) }
        // Without the sign-in probe's empty token.
        let secrets = await harness.factory.secrets.filter { $0 != .bearerToken("") }
        #expect(secrets == [.password("secret"), .bearerToken(candidateAccess), .password("secret")])
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(harness.credentials.loadPassword(for: browserJID.description) == "secret")
        #expect(try await harness.store.fetchAccounts().first?.signInMethod == .password)
        await harness.service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed afterConnect whose account cannot be removed still revokes and deletes the stored candidate once`() async throws {
        let harness = BrowserSignInHarness()
        await harness.store.setDeleteAccountError(TestError())

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in throw TestError() }
        }))

        #expect(error is TestError)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
        let id = try #require(try await harness.store.fetchAccounts().first?.id)
        #expect(harness.service.client(for: id) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed afterConnect whose account cannot be removed revokes the grant stored since, not the candidate`() async throws {
        let harness = BrowserSignInHarness()
        await harness.store.setDeleteAccountError(TestError())
        let rotated = SSOFixtures.grant(access: "rotated-access", refresh: "rotated-refresh")

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in
                // A refresh rotated the committed grant meanwhile.
                try harness.credentials.saveGrant(rotated, for: browserJID)
                throw TestError()
            }
        }))

        #expect(error is TestError)
        #expect(harness.provider.revokedTokens == ["rotated-refresh"])
        #expect(try harness.storedGrant == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed afterConnect whose account cannot be removed and whose grant cannot be read revokes the candidate`() async throws {
        let harness = BrowserSignInHarness()
        await harness.store.setDeleteAccountError(TestError())

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in
                harness.credentials.failSecretReads(true)
                throw TestError()
            }
        }))

        #expect(error is TestError)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        harness.credentials.failSecretReads(false)
        #expect(try harness.storedGrant == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed afterConnect whose account was removed and added again leaves the new account's grant alone`() async throws {
        let harness = BrowserSignInHarness()
        let replacement = Account(id: UUID(), jid: browserJID, isEnabled: true, connectOnLaunch: false, signInMethod: .browser, createdAt: Date())

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { id in
                try await harness.service.deleteAccount(id)
                try await harness.store.saveAccount(replacement)
                try harness.credentials.saveGrant(SSOFixtures.grant(access: storedAccess, refresh: storedRefresh), for: browserJID)
                throw TestError()
            }
        }))

        #expect(error is TestError)
        #expect(try await harness.store.fetchAccounts().map(\.id) == [replacement.id])
        #expect(try harness.storedGrant?.refreshToken == storedRefresh)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
    }

    @Test(.timeLimit(.minutes(1)))
    func `A failed afterConnect whose account cannot be removed or read back still revokes and deletes the candidate`() async throws {
        let harness = BrowserSignInHarness()

        let error = try #require(await boundedFailure(of: Task {
            try await harness.service.addBrowserAccount(address: browserJID.description) { _ in
                await harness.store.setDeleteAccountError(TestError())
                await harness.store.setFetchAccountsError(TestError())
                throw TestError()
            }
        }))

        #expect(error is TestError)
        #expect(harness.provider.revokedTokens == [candidateRefresh])
        #expect(try harness.storedGrant == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Removing an account the service has not loaded yet still ends its grant`() async throws {
        let harness = BrowserSignInHarness()
        let account = Account(id: UUID(), jid: browserJID, isEnabled: true, connectOnLaunch: false, signInMethod: .browser, createdAt: Date())
        try await harness.store.saveAccount(account)
        try harness.credentials.saveGrant(SSOFixtures.grant(access: storedAccess, refresh: storedRefresh), for: browserJID)
        #expect(harness.service.accounts.isEmpty)

        try await harness.service.deleteAccount(account.id)

        #expect(harness.provider.revokedTokens == [storedRefresh])
        #expect(try harness.storedGrant == nil)
        #expect(try await harness.store.fetchAccounts().isEmpty)
    }
}
