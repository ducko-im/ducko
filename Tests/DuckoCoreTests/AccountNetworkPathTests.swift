import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// A network path the test changes by hand.
@MainActor
private struct FakeNetworkPath {
    let source: NetworkPathSource
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        self.source = NetworkPathSource { stream }
        self.continuation = continuation
    }

    func change(hasRoute: Bool) {
        continuation.yield(hasRoute)
    }
}

@MainActor
private func makeService(factory: AccountConnectionFactoryProbe, path: FakeNetworkPath) -> AccountService {
    let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory, networkPath: path.source)
    service.retriesFailedConnects = true
    service.reconnectDelay = { _ in .zero }
    return service
}

@MainActor
private func awaitNoNetwork(_ service: AccountService, accountID: UUID) async throws {
    try await eventually {
        if case .error(AccountService.noNetworkMessage) = service.connectionStates[accountID] { true } else { false }
    }
}

private func unreachable() -> MockTransport {
    MockTransport(connectError: XMPPClientError.connectionFailed("unreachable"))
}

@MainActor
struct AccountNetworkPathTests {
    @Test
    func `a launch without a network waits for a route, then connects once its retry is due`() async throws {
        let path = FakeNetworkPath()
        let factory = AccountConnectionFactoryProbe(transports: [unreachable(), MockTransport()])
        let service = makeService(factory: factory, path: path)
        service.reconnectDelay = { _ in .milliseconds(400) }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        path.change(hasRoute: false)
        try await awaitNoNetwork(service, accountID: id)
        // Past the moment the paused retry was due.
        try await Task.sleep(for: .milliseconds(600))
        #expect(await factory.requestCount == 1)

        path.change(hasRoute: true)
        try await eventually { await factory.requestCount == 2 }
        await service.disconnect(accountID: id)
    }

    @Test
    func `a connection lost without a route waits for one, then retries once`() async throws {
        let path = FakeNetworkPath()
        let original = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [original, MockTransport()])
        let service = makeService(factory: factory, path: path)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: original)

        path.change(hasRoute: false)
        await original.simulateDisconnect()
        try await awaitNoNetwork(service, accountID: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await factory.requestCount == 1)

        path.change(hasRoute: true)
        try await eventually { await factory.requestCount == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await factory.requestCount == 2)
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `a flapping network neither beats the backoff nor skips an attempt`() async throws {
        let path = FakeNetworkPath()
        let factory = AccountConnectionFactoryProbe(transports: [unreachable(), unreachable(), MockTransport()])
        let service = makeService(factory: factory, path: path)
        let attempts = OSAllocatedUnfairLock<[Int]>(initialState: [])
        service.reconnectDelay = { attempt in
            attempts.withLock { $0.append(attempt) }
            return .milliseconds(500)
        }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        for _ in 0 ..< 3 {
            path.change(hasRoute: false)
            path.change(hasRoute: true)
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(await factory.requestCount == 1)

        try await eventually { await factory.requestCount == 3 }
        #expect(attempts.withLock { $0 } == [0, 1])
        await service.disconnect(accountID: id)
    }

    @Test
    func `a lost route leaves a retry that is already connecting alone`() async throws {
        let path = FakeNetworkPath()
        let release = AsyncSemaphore()
        let retry = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [unreachable(), retry], laterRelease: release)
        let service = makeService(factory: factory, path: path)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        // The retry waits in client construction, past the moment it began connecting.
        try await eventually { await factory.requestCount == 2 }
        path.change(hasRoute: false)
        try await eventually { !service.hasNetworkRoute }

        #expect(service.connectionResources[id]?.reconnectTask?.isCancelled == false)
        await release.signal()
        try await eventually { await retry.connectedHost != nil }
        await service.disconnect(accountID: id)
    }

    @Test(arguments: [true, false])
    func `a network change keeps a session that answers its ping and ends one that does not`(answers: Bool) async throws {
        let path = FakeNetworkPath()
        let original = MockTransport()
        if answers {
            await original.autoReply { stanza in
                guard stanza.contains(XMPPNamespaces.ping), let id = extractIQID(from: stanza) else { return nil }
                return "<iq type='result' id='\(id)'/>"
            }
        }
        let factory = AccountConnectionFactoryProbe(transports: [original, MockTransport()], pings: true)
        let service = makeService(factory: factory, path: path)
        service.networkProbeTimeout = .milliseconds(200)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (client, connection) = try await driveMockConnect(service, accountID: id, transport: original)

        path.change(hasRoute: true)
        _ = try await sentStanza(on: original, containing: "urn:xmpp:ping")

        if answers {
            try await Task.sleep(for: .milliseconds(400))
            #expect(service.connectedClient(for: id) === client)
            #expect(await factory.requestCount == 1)
        } else {
            try await eventually { await factory.requestCount == 2 }
        }
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `disconnecting an account waiting for a route keeps a returning route from connecting it`() async throws {
        let path = FakeNetworkPath()
        let original = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [original, MockTransport()])
        let service = makeService(factory: factory, path: path)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: original)

        path.change(hasRoute: false)
        await original.simulateDisconnect()
        try await awaitNoNetwork(service, accountID: id)
        #expect(service.connectionResources[id]?.client == nil)
        #expect(service.connectionResources[id]?.awaitingRoute == true)
        await service.disconnectAll()
        _ = await connection.result
        path.change(hasRoute: true)
        try await Task.sleep(for: .milliseconds(200))

        #expect(await factory.requestCount == 1)
        guard case .disconnected = service.connectionStates[id] else {
            Issue.record("Expected disconnected, got \(String(describing: service.connectionStates[id]))")
            return
        }
    }

    @Test
    func `connecting an account waiting for a route leaves a returning route nothing to start`() async throws {
        let path = FakeNetworkPath()
        let factory = AccountConnectionFactoryProbe(transports: [unreachable(), MockTransport()])
        let service = makeService(factory: factory, path: path)
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        path.change(hasRoute: false)
        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        try await awaitNoNetwork(service, accountID: id)

        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        try await eventually { await factory.requestCount == 2 }
        path.change(hasRoute: true)
        try await Task.sleep(for: .milliseconds(200))

        #expect(await factory.requestCount == 2)
        await service.disconnect(accountID: id)
        _ = await connection.result
    }
}
