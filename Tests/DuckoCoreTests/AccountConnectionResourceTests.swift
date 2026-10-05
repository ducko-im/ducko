import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct AccountConnectionResourceTests {
    @Test
    func `late factory completion cannot resurrect a disconnected account`() async throws {
        let transport = MockTransport()
        let release = AsyncSemaphore()
        let factory = AccountConnectionFactoryProbe(transports: [transport], firstRelease: release)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com")
        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        let request = try await factory.nextRequest()
        #expect(request.password == "secret")
        await service.disconnect(accountID: id)
        await release.signal()
        await #expect(throws: CancellationError.self) { try await connection.value }
        #expect(service.client(for: id) == nil)
        #expect(await transport.connectedHost == nil)
        guard case .disconnected = service.connectionStates[id] else {
            Issue.record("Late client construction changed the disconnected state")
            return
        }
    }

    @Test
    func `failed connection retains resumable state until explicit disconnect`() async throws {
        let bare = try #require(BareJID.parse("alice@example.com"))
        let full = try #require(FullJID(bareJID: bare, resourcePart: "resume"))
        let resume = SMResumeState(resumptionId: "saved-session", incomingCounter: 7, outgoingCounter: 9, outgoingQueue: [], connectedJID: full, location: "resume.example.com:5223")
        let transports = (0 ..< 3).map { _ in MockTransport(connectError: AccountConnectionFactoryProbe.Failure.connect) }
        let factory = AccountConnectionFactoryProbe(transports: transports, initialResume: resume)
        let credentials = MockCredentialStore()
        let service = AccountService(store: MockPersistenceStore(), credentialStore: credentials, clientFactory: factory)
        let id = try await service.createAccount(jidString: bare.description)
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await service.connect(accountID: id, password: "secret") }
        let first = try await factory.nextRequest()
        #expect(first.resume == nil)
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await service.connect(accountID: id, password: "secret") }
        let retry = try await factory.nextRequest()
        #expect(retry.resume?.streamManagement.resumptionId == "saved-session")
        #expect(retry.resume?.streamManagement.incomingCounter == 7)
        #expect(retry.resume?.streamManagement.outgoingCounter == 9)
        await service.disconnect(accountID: id)
        await service.savePassword(accountID: id)
        #expect(credentials.loadPassword(for: bare.description) == nil)
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await service.connect(accountID: id, password: "replacement") }
        let fresh = try await factory.nextRequest()
        #expect(fresh.resume == nil)
        #expect(fresh.password == "replacement")
        await service.disconnect(accountID: id)
    }

    @Test
    func `shutdown includes an account waiting for reconnect without a live client`() async throws {
        let transport = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [transport])
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com")
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: transport)
        let disconnected = AsyncStream.makeStream(of: Void.self)
        service.onEvent = { event, _ in
            if case .disconnected = event { disconnected.continuation.yield(()); disconnected.continuation.finish() }
        }
        var requested: [UUID] = []
        service.onRequestedDisconnect = { requested.append($0) }
        await transport.simulateDisconnect()
        try await waitForEvent(disconnected.stream) { _ in true }
        #expect(service.client(for: id) == nil)
        #expect(requested.isEmpty)
        await service.disconnectAll()
        #expect(requested == [id])
        #expect(await factory.requestCount == 1)
        _ = await connection.result
    }

    @Test
    func `redirect forces TLS and disconnect invalidates its suspended factory`() async throws {
        let original = MockTransport()
        let redirected = MockTransport()
        let release = AsyncSemaphore()
        let factory = AccountConnectionFactoryProbe(transports: [original, redirected], laterRelease: release)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: original)
        _ = try await factory.nextRequest()
        await original.simulateReceive("<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>")
        let request = try await factory.nextRequest()
        #expect(request.requireTLS == true)
        #expect(request.password == "secret")
        #expect(request.resume == nil)
        await service.disconnect(accountID: id)
        await release.signal()
        try await waitForEvent(request.disconnections) { _ in true }
        #expect(service.client(for: id) == nil)
        #expect(await redirected.connectedHost == nil)
        _ = await connection.result
    }

    @Test
    func `a redirected session's room module is the one the account hands out`() async throws {
        let original = MockTransport()
        let redirected = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [original, redirected])
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (first, connection) = try await driveMockConnect(service, accountID: id, transport: original)

        await original.simulateReceive("<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>")
        try await suspendAtStreamManagement(redirected, requiresTLS: true)
        await redirected.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='redirected-session' max='300'/>")
        try await eventually { service.connectedClient(for: id).map { $0 !== first } ?? false }

        let client = try #require(service.connectedClient(for: id))
        let roomModule = try #require(service.roomModule(for: id))
        #expect(await client.module(ofType: MUCModule.self) === roomModule)
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `fourth redirect during stream management setup reaches the limit`() async throws {
        let transports = (0 ..< 4).map { _ in MockTransport() }
        let factory = AccountConnectionFactoryProbe(transports: transports)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let redirects = AsyncStream.makeStream(of: Void.self)
        service.onEvent = { event, _ in
            if case .disconnected(.redirect) = event { redirects.continuation.yield(()) }
        }
        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        do {
            for (index, transport) in transports.enumerated() {
                let request = try await factory.nextRequest()
                #expect(request.requireTLS == (index == 0 ? nil : true))
                try await suspendAtStreamManagement(transport, requiresTLS: index > 0)
                await transport.simulateReceive("<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5222</see-other-host></error>")
                try await waitForEvent(redirects.stream) { _ in true }
            }
            if case let .error(message) = service.connectionStates[id] {
                #expect(message == "The server redirected too many times")
            } else {
                Issue.record("Fourth redirect did not reach the redirect limit")
            }
            #expect(service.client(for: id) == nil)
            #expect(await factory.requestCount == 4)
        } catch {
            await service.disconnect(accountID: id)
            connection.cancel()
            _ = await connection.result
            throw error
        }
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `redirect account read failure leaves a terminal error`() async throws {
        let transport = MockTransport()
        let store = MockPersistenceStore()
        let factory = AccountConnectionFactoryProbe(transports: [transport])
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com")
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: transport)
        await store.setFetchAccountsError(AccountConnectionFactoryProbe.Failure.connect)
        await transport.simulateReceive("<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5223</see-other-host></error>")
        let settled = try await boundedOutcome { @MainActor in
            while true {
                if case .error = service.connectionStates[id] { return }
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        try #require(settled != nil)
        try settled?.get()
        #expect(service.client(for: id) == nil)
        #expect(await factory.requestCount == 1)
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `connect account read failure leaves a terminal error`() async throws {
        let store = MockPersistenceStore()
        let factory = AccountConnectionFactoryProbe(transports: [])
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com")
        await store.setFetchAccountsError(AccountConnectionFactoryProbe.Failure.connect)
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await service.connect(accountID: id, password: "secret") }
        guard case .error = service.connectionStates[id] else {
            Issue.record("A failed account read left \(String(describing: service.connectionStates[id]))")
            return
        }
        #expect(await factory.requestCount == 0)
    }

    @Test
    func `superseded connect cannot strand the account connecting when the newer account read fails`() async throws {
        let store = MockPersistenceStore()
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: AccountConnectionFactoryProbe(transports: []))
        let id = try await service.createAccount(jidString: "alice@example.com")
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installFetchAccountsGate(entered: entered, release: release)
        let first = Task { try await service.connect(accountID: id, password: "secret") }
        let held = try await boundedOutcome { await entered.wait() }
        #expect(held != nil)

        // The second connect supersedes the held one while it still shows `.connecting`, then fails its own read.
        await store.setFetchAccountsError(AccountConnectionFactoryProbe.Failure.connect)
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await service.connect(accountID: id, password: "secret") }
        await release.signal()
        _ = await first.result

        guard case .error = service.connectionStates[id] else {
            Issue.record("The superseded attempt left \(String(describing: service.connectionStates[id]))")
            return
        }
    }

    @Test
    func `superseded connect's failed account read leaves the newer attempt connecting`() async throws {
        let store = MockPersistenceStore()
        let factoryRelease = AsyncSemaphore()
        let factory = AccountConnectionFactoryProbe(transports: [MockTransport()], firstRelease: factoryRelease)
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: factory)
        let id = try await service.createAccount(jidString: "alice@example.com")
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installFetchAccountsGate(entered: entered, release: release)
        let first = Task { try await service.connect(accountID: id, password: "secret") }
        let held = try await boundedOutcome { await entered.wait() }
        #expect(held != nil)

        // The newer connect reads the account and waits in client construction, still `.connecting`.
        let second = Task { try await service.connect(accountID: id, password: "secret") }
        _ = try await factory.nextRequest()
        await store.setFetchAccountsError(AccountConnectionFactoryProbe.Failure.connect)
        await release.signal()
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await first.value }
        guard case .connecting = service.connectionStates[id] else {
            Issue.record("The superseded attempt's failure replaced the newer attempt's state")
            return
        }

        await service.disconnect(accountID: id)
        await factoryRelease.signal()
        _ = await second.result
    }

    @Test
    func `cancelled connect waiting on the account read settles disconnected`() async throws {
        let store = MockPersistenceStore()
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: AccountConnectionFactoryProbe(transports: []))
        let id = try await service.createAccount(jidString: "alice@example.com")
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installFetchAccountsGate(entered: entered, release: release)
        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        let held = try await boundedOutcome { await entered.wait() }
        #expect(held != nil)
        guard case .connecting = service.connectionStates[id] else {
            Issue.record("The held connect didn't publish connecting")
            return
        }

        connection.cancel()
        await release.signal()
        await #expect(throws: CancellationError.self) { try await connection.value }
        guard case .disconnected = service.connectionStates[id] else {
            Issue.record("The cancelled attempt left \(String(describing: service.connectionStates[id]))")
            return
        }
    }

    @Test
    func `failed account read keeps the state a certificate rejection published`() async throws {
        let store = MockPersistenceStore()
        let service = AccountService(store: store, credentialStore: MockCredentialStore(), clientFactory: AccountConnectionFactoryProbe(transports: []))
        let id = try await service.createAccount(jidString: "alice@example.com")
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installFetchAccountsGate(entered: entered, release: release)
        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        let held = try await boundedOutcome { await entered.wait() }
        #expect(held != nil)

        // Rejecting publishes `.disconnected` without replacing the attempt, so only the state tells the read apart.
        await service.rejectNewCertificate(for: id)
        await store.setFetchAccountsError(AccountConnectionFactoryProbe.Failure.connect)
        await release.signal()
        await #expect(throws: AccountConnectionFactoryProbe.Failure.self) { try await connection.value }
        guard case .disconnected = service.connectionStates[id] else {
            Issue.record("The failed read overwrote the rejection with \(String(describing: service.connectionStates[id]))")
            return
        }
    }

    private func suspendAtStreamManagement(_ transport: MockTransport, requiresTLS: Bool) async throws {
        try await exchange(transport, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesNoTLS)
        if requiresTLS {
            try await exchange(transport, matching: "<starttls", response: "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
            try await exchange(transport, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesNoTLS)
        }
        try await exchange(transport, matching: "<auth", response: "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await exchange(transport, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesBindWithSM)
        try await exchange(transport, matching: "<iq", response: testBindResult)
        try await exchange(transport, matching: "<enable", response: "")
    }

    private func exchange(_ transport: MockTransport, matching fragment: String, response: String) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                guard await transport.waitForSent(matching: { $0.contains(fragment) }) != nil else { throw CancellationError() }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AccountConnectionFactoryProbe.Failure.timeout
            }
            try await group.next()
        }
        await transport.clearSentBytes()
        await transport.simulateReceive(response)
    }

    private func waitForEvent<Event: Sendable>(_ stream: AsyncStream<Event>, matching: @escaping @Sendable (Event) -> Bool) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { group.cancelAll() }
            group.addTask {
                for await event in stream where matching(event) {
                    return
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AccountConnectionFactoryProbe.Failure.timeout
            }
            try await group.next()
        }
    }
}

private actor AccountConnectionFactoryProbe: XMPPClientFactory {
    enum Failure: Error { case connect, timeout }
    struct Request {
        let password: String
        let resume: StreamResumeContext?
        let requireTLS: Bool?
        let disconnections: AsyncStream<Void>
    }

    private let transports: [MockTransport]
    private let initialResume: SMResumeState?
    private let firstRelease: AsyncSemaphore?
    private let laterRelease: AsyncSemaphore?
    private let requests = AsyncStream.makeStream(of: Request.self)
    private(set) var requestCount = 0

    init(transports: [MockTransport], initialResume: SMResumeState? = nil, firstRelease: AsyncSemaphore? = nil, laterRelease: AsyncSemaphore? = nil) {
        self.transports = transports
        self.initialResume = initialResume
        self.firstRelease = firstRelease
        self.laterRelease = laterRelease
    }

    func makeClient(account: Account, password: String, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?) async -> (XMPPClient, StreamManagementModule) {
        let index = requestCount
        requestCount += 1
        let transport = index < transports.count ? transports[index] : MockTransport(connectError: Failure.connect)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement ?? (index == 0 ? initialResume : nil))
        var builder = XMPPClientBuilder(domain: account.jid.domainPart, username: account.jid.localPart ?? "", password: password)
        let observed = AccountConnectionTransport(mock: transport)
        builder.withTransport(observed)
        builder.withRequireTLS(requireTLSOverride ?? false)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        builder.withModule(MUCModule(resuming: resuming?.rooms))
        // A requested disconnect waits for the server to acknowledge what was sent.
        await transport.ackSyncRequests(from: sm)
        let client = await builder.build()
        requests.continuation.yield(Request(password: password, resume: resuming, requireTLS: requireTLSOverride, disconnections: observed.disconnections))
        if index == 0 { await firstRelease?.wait() } else { await laterRelease?.wait() }
        return (client, sm)
    }

    func nextRequest() async throws -> Request {
        let stream = requests.stream
        return try await withThrowingTaskGroup(of: Request?.self) { group in
            defer { group.cancelAll() }
            group.addTask { for await request in stream {
                return request
            }; return nil }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw Failure.timeout
            }
            return try #require(await group.next()!)
        }
    }
}

private actor AccountConnectionTransport: XMPPTransport {
    nonisolated let mock: MockTransport
    nonisolated var receivedData: AsyncStream<[UInt8]> {
        mock.receivedData
    }

    nonisolated let disconnections: AsyncStream<Void>
    private let disconnected: AsyncStream<Void>.Continuation

    init(mock: MockTransport) {
        self.mock = mock
        let signal = AsyncStream.makeStream(of: Void.self)
        self.disconnections = signal.stream
        self.disconnected = signal.continuation
    }

    func connect(host: String, port: UInt16) async throws {
        try await mock.connect(host: host, port: port)
    }

    func connectWithTLS(host: String, port: UInt16, serverName: String) async throws {
        try await mock.connectWithTLS(host: host, port: port, serverName: serverName)
    }

    func stopReceiving() async {
        await mock.stopReceiving()
    }

    func upgradeTLS(serverName: String) async throws -> AsyncStream<[UInt8]> {
        try await mock.upgradeTLS(serverName: serverName)
    }

    func send(_ bytes: [UInt8]) async throws {
        try await mock.send(bytes)
    }

    func disconnect() async {
        await mock.disconnect()
        disconnected.yield(())
        disconnected.finish()
    }
}
