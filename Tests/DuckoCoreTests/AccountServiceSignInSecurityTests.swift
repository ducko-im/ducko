import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private func makeAccount() throws -> Account {
    try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
}

/// An account service over `store` whose clients sign in on `transport`.
@MainActor
private func makeService(store: MockPersistenceStore, transport: MockTransport) async throws -> AccountService {
    let service = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport))
    try await service.loadAccounts()
    return service
}

@MainActor
struct AccountServiceSignInSecurityTests {
    @Test
    func `A SCRAM sign-in that fails at binding still requires SCRAM, and the next PLAIN-only offer gets no password`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let first = MockTransport()
        let service = try await makeService(store: store, transport: first)
        var server = SCRAMTestServer(password: "secret")

        let signIn = Task { try await service.connect(accountID: account.id, password: "secret") }
        try await server.playSASL1SignIn(on: first)
        await first.waitForSent(count: 4) // post-auth stream opening
        await first.simulateReceive(testServerStreamOpen)
        await first.simulateReceive(testFeaturesBind)
        await first.waitForSent(count: 5) // bind IQ
        await first.simulateReceive("<iq type='error' id='bind'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        await #expect(throws: XMPPClientError.self) { try await signIn.value }
        #expect(try await store.fetchAccounts().first?.requiresSCRAM == true)

        let second = MockTransport()
        let nextService = try await makeService(store: store, transport: second)
        let refused = Task { try await nextService.connect(accountID: account.id, password: "secret") }
        await second.waitForSent(count: 1) // stream opening
        await second.simulateReceive(testServerStreamOpen)
        await second.simulateReceive(testFeaturesNoTLS)

        let error = try #require(await boundedFailure(of: refused))
        guard case .plainSignInRefused = error as? XMPPClientError else {
            Issue.record("Expected plainSignInRefused, got \(error)")
            await nextService.disconnect(accountID: account.id)
            return
        }
        #expect(await second.sentBytes.count == 1)
        #expect(!AccountService.isCredentialsRejected(error))
        try await eventually { nextService.signInSecurityWarnings[account.id]?.accountJID == testJIDString }
    }

    @Test
    func `A SCRAM sign-in that completes requires SCRAM from then on`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        var server = SCRAMTestServer(password: "secret")

        let signIn = Task { try await service.connect(accountID: account.id, password: "secret") }
        try await server.playSASL1SignIn(on: transport)
        await transport.waitForSent(count: 4) // post-auth stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesBind)
        await transport.waitForSent(count: 5) // bind IQ
        await transport.simulateReceive(testBindResult)
        try await signIn.value

        #expect(try await store.fetchAccounts().first?.requiresSCRAM == true)
        #expect(service.accounts.first?.requiresSCRAM == true)
        await service.disconnect(accountID: account.id)
    }

    @Test
    func `A PLAIN sign-in does not require SCRAM`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)

        let (client, task) = try await driveMockConnect(service, accountID: account.id, transport: transport)
        try await task.value

        #expect(try await store.fetchAccounts().first?.requiresSCRAM == false)
        await client.disconnect()
    }

    @Test
    func `Resetting sign-in security clears the requirement and the warning`() async throws {
        let store = MockPersistenceStore()
        var account = try makeAccount()
        account.requiresSCRAM = true
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        let refused = Task { try await service.connect(accountID: account.id, password: "secret") }
        await transport.waitForSent(count: 1) // stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesNoTLS)
        _ = try await boundedFailure(of: refused)
        try await eventually { service.signInSecurityWarnings[account.id] != nil }

        try await service.resetSignInSecurity(for: account.id)

        #expect(try await store.fetchAccounts().first?.requiresSCRAM == false)
        #expect(service.signInSecurityWarnings[account.id] == nil)
    }
}
