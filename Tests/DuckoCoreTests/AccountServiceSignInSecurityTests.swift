import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private func makeAccount(allowsPLAIN: Bool = false) throws -> Account {
    try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, allowsPLAIN: allowsPLAIN, createdAt: Date())
}

/// An account service over `store` whose clients sign in on `transport`, as each account's permission says.
@MainActor
private func makeService(store: MockPersistenceStore, transport: MockTransport) async throws -> AccountService {
    let service = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, allowsPLAIN: nil))
    try await service.loadAccounts()
    return service
}

/// Answers a stream opening on `transport` with features that offer only PLAIN.
private func offerOnlyPLAIN(on transport: MockTransport) async {
    await transport.waitForSent(count: 1) // stream opening
    await transport.simulateReceive(testServerStreamOpen)
    await transport.simulateReceive(testFeaturesNoTLS)
}

@MainActor
struct AccountServiceSignInSecurityTests {
    @Test
    func `By default an offer of only PLAIN gets no password and publishes a warning`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)

        let refused = Task { try await service.connect(accountID: account.id, password: "secret") }
        await offerOnlyPLAIN(on: transport)

        let error = try #require(await boundedFailure(of: refused))
        #expect(AccountService.isPLAINRefusal(error))
        #expect(!AccountService.isCredentialsRejected(error))
        #expect(await transport.sentBytes.count == 1)
        try await eventually { service.signInSecurityWarnings[account.id]?.accountJID == testJIDString }
    }

    @Test
    func `Allowing PLAIN stores the permission and clears the warning`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        let refused = Task { try await service.connect(accountID: account.id, password: "secret") }
        await offerOnlyPLAIN(on: transport)
        _ = try await boundedFailure(of: refused)
        try await eventually { service.signInSecurityWarnings[account.id] != nil }

        try await service.setAllowsPLAIN(true, for: account.id)

        #expect(try await store.fetchAccounts().first?.allowsPLAIN == true)
        #expect(service.accounts.first?.allowsPLAIN == true)
        #expect(service.signInSecurityWarnings[account.id] == nil)
    }

    @Test
    func `A SCRAM sign-in that fails at binding still turns PLAIN off`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount(allowsPLAIN: true)
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)

        let signIn = Task { try await service.connect(accountID: account.id, password: "secret") }
        try await playSCRAMSession(
            on: transport,
            bindReply: "<iq type='error' id='bind'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
        )
        await #expect(throws: XMPPClientError.self) { try await signIn.value }

        #expect(try await store.fetchAccounts().first?.allowsPLAIN == false)
    }

    @Test
    func `A SCRAM sign-in turns PLAIN off even when it was allowed during that sign-in`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount()
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        var server = SCRAMTestServer(password: "secret")

        let signIn = Task { try await service.connect(accountID: account.id, password: "secret") }
        await transport.waitForSent(count: 1) // stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(SCRAMTestServer.sasl1Features)
        let auth = try #require(await transport.waitForSent { $0.hasPrefix("<auth ") })
        let first = try server.serverFirst(answering: #require(SCRAMTestServer.payload(in: auth)))
        await transport.simulateReceive("<challenge xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(first)</challenge>")
        let response = try #require(await transport.waitForSent { $0.hasPrefix("<response ") })
        try await service.setAllowsPLAIN(true, for: account.id)
        let verifier = try server.serverFinal(answering: #require(SCRAMTestServer.payload(in: response)))
        await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>\(verifier)</success>")
        await transport.waitForSent(count: 4) // post-auth stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesBind)
        await transport.waitForSent(count: 5) // bind IQ
        await transport.simulateReceive(testBindResult)
        try await signIn.value

        #expect(try await store.fetchAccounts().first?.allowsPLAIN == false)
        #expect(service.accounts.first?.allowsPLAIN == false)
        await service.disconnect(accountID: account.id)
    }

    @Test
    func `Saving an edit begun before a SCRAM sign-in keeps PLAIN off`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount(allowsPLAIN: true)
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        let opened = try #require(service.accounts.first)

        let signIn = Task { try await service.connect(accountID: account.id, password: "secret") }
        try await playSCRAMSession(on: transport)
        try await signIn.value
        #expect(try await store.fetchAccounts().first?.allowsPLAIN == false)
        // The sheet saves the account as the service holds it at that moment.
        var edited = try #require(service.accounts.first)
        edited.displayName = "Juliet"
        try await service.updateAccount(edited, allowsPLAIN: opened.allowsPLAIN, openedWith: opened.allowsPLAIN)

        let saved = try #require(try await store.fetchAccounts().first)
        #expect(saved.displayName == "Juliet")
        #expect(!saved.allowsPLAIN)
        await service.disconnect(accountID: account.id)
    }

    @Test(arguments: [false, true])
    func `An edit that changes the PLAIN permission stores it`(allowed: Bool) async throws {
        let store = MockPersistenceStore()
        try await store.saveAccount(makeAccount(allowsPLAIN: !allowed))
        let service = try await makeService(store: store, transport: MockTransport())
        let opened = try #require(service.accounts.first)

        try await service.updateAccount(opened, allowsPLAIN: allowed, openedWith: opened.allowsPLAIN)

        #expect(try await store.fetchAccounts().first?.allowsPLAIN == allowed)
    }

    @Test
    func `A PLAIN sign-in the account allows leaves the permission on`() async throws {
        let store = MockPersistenceStore()
        let account = try makeAccount(allowsPLAIN: true)
        try await store.saveAccount(account)
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)

        let (client, task) = try await driveMockConnect(service, accountID: account.id, transport: transport)
        try await task.value

        #expect(try await store.fetchAccounts().first?.allowsPLAIN == true)
        await client.disconnect()
    }

    @Test
    func `An added account refused at its first sign-in is rolled back without a warning`() async throws {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)
        var warnedAtRefusal: Bool?
        service.onEvent = { event, accountID in
            if case .plainSignInRefused = event { warnedAtRefusal = service.signInSecurityWarnings[accountID] != nil }
        }

        let creation = Task { try await service.createAndConnect(jidString: testJIDString, password: "secret") }
        await offerOnlyPLAIN(on: transport)

        let error = try #require(await boundedFailure(of: creation))
        #expect(AccountService.isPLAINRefusal(error))
        // The rollback can drop the session before the refusal event is delivered, so `warnedAtRefusal` may stay nil.
        #expect(warnedAtRefusal != true)
        #expect(service.signInSecurityWarnings.isEmpty)
        #expect(try await store.fetchAccounts().isEmpty)
    }

    @Test
    func `An added account's later refused sign-in publishes the warning`() async throws {
        let added = MockTransport()
        let later = MockTransport()
        let service = makeAccountService(
            store: MockPersistenceStore(), clientFactory: AccountConnectionFactoryProbe(transports: [added, later], allowsPLAIN: nil)
        )
        let creation = Task { try await service.createAndConnect(jidString: testJIDString, password: "secret") }
        try await playSCRAMSession(on: added)
        let accountID = try await creation.value
        await service.disconnect(accountID: accountID)

        let refused = Task { try await service.connect(accountID: accountID, password: "secret") }
        await offerOnlyPLAIN(on: later)

        #expect(try AccountService.isPLAINRefusal(#require(await boundedFailure(of: refused))))
        try await eventually { service.signInSecurityWarnings[accountID] != nil }
    }

    @Test
    func `An account added with PLAIN allowed signs in with it and keeps the permission`() async throws {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        let service = try await makeService(store: store, transport: transport)

        let creation = Task { try await service.createAndConnect(jidString: testJIDString, password: "secret", allowsPLAIN: true) }
        await simulateNoTLSConnect(transport)
        let accountID = try await creation.value

        #expect(try await store.fetchAccounts().first { $0.id == accountID }?.allowsPLAIN == true)
        await service.disconnect(accountID: accountID)
    }

    @Test(arguments: [false, true])
    func `A registered account's first sign-in allows PLAIN until a SCRAM sign-in`(offersSCRAM: Bool) async throws {
        let store = MockPersistenceStore()
        let signInTransport = MockTransport()
        let registrationTransport = MockTransport()
        let service = try await makeService(store: store, transport: signInTransport)
        service.openRegistrationSession = { domain, host, port in
            try await RegistrationSession.open(domain: domain, host: host ?? domain, port: port, transport: registrationTransport)
        }

        let registration = Task { @MainActor in
            try await service.registerAccount(domain: "example.com", username: "juliet", password: "secret")
        }
        try await completeRegistration(on: registrationTransport)
        if offersSCRAM {
            try await playSCRAMSession(on: signInTransport)
        } else {
            await simulateNoTLSConnect(signInTransport)
        }
        guard case let .registered(accountID) = try await registration.value else {
            Issue.record("Expected the registration to complete")
            return
        }

        #expect(try await store.fetchAccounts().first { $0.id == accountID }?.allowsPLAIN == !offersSCRAM)
        await service.disconnect(accountID: accountID)
    }

    @Test
    func `Only a refusal to send the password counts as a PLAIN refusal`() {
        #expect(AccountService.isPLAINRefusal(XMPPClientError.plainSignInRefused))
        #expect(!AccountService.isPLAINRefusal(XMPPClientError.tlsRequired))
        #expect(!AccountService.isPLAINRefusal(XMPPClientError.authenticationFailed(AuthenticationFailure(kind: .credentialsRejected, message: "denied"))))
    }
}
