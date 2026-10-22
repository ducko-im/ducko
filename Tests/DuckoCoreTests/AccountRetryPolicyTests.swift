import DuckoTestSupport
import Foundation
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct AccountRetryPolicyTests {
    private static let seeOtherHost = "<error><see-other-host xmlns='urn:ietf:params:xml:ns:xmpp-streams'>redirect.example.com:5222</see-other-host></error>"

    @Test(arguments: [true, false])
    func `a failed connect the app started is retried, one from the command line is not`(retries: Bool) async throws {
        let factory = AccountConnectionFactoryProbe(transports: [MockTransport(connectError: XMPPClientError.connectionFailed("unreachable")), MockTransport()])
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.retriesFailedConnects = retries
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        if retries {
            try await eventually { await factory.requestCount == 2 }
        } else {
            try await Task.sleep(for: .milliseconds(200))
            #expect(await factory.requestCount == 1)
        }
        await service.disconnect(accountID: id)
    }

    @Test
    func `the app retries the connects it starts`() {
        let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())

        #expect(environment.accountService.retriesFailedConnects)
    }

    @Test
    func `an untrusted certificate is not retried`() async throws {
        let factory = AccountConnectionFactoryProbe(transports: [MockTransport(connectError: XMPPClientError.untrustedCertificate(.notTrusted))])
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.retriesFailedConnects = true
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        await #expect(throws: XMPPClientError.self) { try await service.connect(accountID: id, password: "secret") }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await factory.requestCount == 1)
        guard case let .error(message) = service.connectionStates[id] else {
            Issue.record("Expected an error, got \(String(describing: service.connectionStates[id]))")
            return
        }
        #expect(message == XMPPClientError.untrustedCertificate(.notTrusted).localizedDescription)
    }

    @Test(arguments: [("not-authorized", false), ("account-disabled", false), ("temporary-auth-failure", true)])
    func `a refused sign-in is retried only when the server failed temporarily`(condition: String, retried: Bool) async throws {
        let refused = MockTransport()
        let factory = AccountConnectionFactoryProbe(transports: [refused, MockTransport()])
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.retriesFailedConnects = true
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        try await exchange(refused, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesNoTLS)
        try await exchange(refused, matching: "<auth", response: "<failure xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><\(condition)/></failure>")
        _ = await connection.result

        if retried {
            try await eventually { await factory.requestCount == 2 }
        } else {
            try await Task.sleep(for: .milliseconds(200))
            #expect(await factory.requestCount == 1)
        }
        await service.disconnect(accountID: id)
    }

    @Test
    func `a redirect whose target cannot be reached is retried at the configured host`() async throws {
        let original = MockTransport()
        let retry = MockTransport()
        let factory = AccountConnectionFactoryProbe(
            transports: [original, MockTransport(connectError: XMPPClientError.connectionFailed("unreachable")), retry]
        )
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", host: "configured.example.com", port: 5222, requireTLS: false)
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: original)
        _ = try await factory.nextRequest()

        await original.simulateReceive(Self.seeOtherHost)
        #expect(try await factory.nextRequest().requireTLS == true)
        let request = try await factory.nextRequest()

        #expect(request.requireTLS == nil)
        try await eventually { await retry.connectedHost == "configured.example.com" }
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `a server that keeps redirecting to an unreachable host is cut off after the fourth redirect`() async throws {
        let healthy = (0 ..< 4).map { _ in MockTransport() }
        let transports = healthy.enumerated().flatMap { index, transport in
            index == 0 ? [transport] : [MockTransport(connectError: XMPPClientError.connectionFailed("unreachable")), transport]
        }
        let factory = AccountConnectionFactoryProbe(transports: transports)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (_, connection) = try await driveMockConnect(service, accountID: id, transport: healthy[0])

        for (index, transport) in healthy.enumerated() {
            if index > 0 {
                // The retry at the configured host completes its setup before the next redirect.
                await simulateNoTLSConnect(transport)
                try await eventually {
                    service.connectedClient(for: id) != nil && service.connectionResources[id]?.reconnectAttempts == 0
                }
            }
            await transport.simulateReceive(Self.seeOtherHost)
            if index < healthy.count - 1 {
                try await eventually { await factory.requestCount == 2 * index + 3 }
            }
        }
        try await eventually {
            if case .error("The server redirected too many times") = service.connectionStates[id] { true } else { false }
        }
        try await Task.sleep(for: .milliseconds(200))

        #expect(await factory.requestCount == transports.count)
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test(arguments: [true, false])
    func `a session whose setup failed is retried fresh only when the failure was transient`(transient: Bool) async throws {
        let original = MockTransport()
        let failure: any Error = transient ? XMPPClientError.timeout : XMPPStanzaError(errorType: .cancel, condition: .notAllowed)
        let factory = AccountConnectionFactoryProbe(transports: [original, MockTransport()], setupFailure: failure)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        _ = try await factory.nextRequest()
        try await exchange(original, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesNoTLS)
        try await exchange(original, matching: "<auth", response: "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await exchange(original, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesBindWithSM)
        try await exchange(original, matching: "<iq", response: testBindResult)
        try await exchange(original, matching: "<enable", response: "<enabled xmlns='urn:xmpp:sm:3' resume='true' id='setup-session'/>")
        _ = await connection.result

        if transient {
            #expect(try await factory.nextRequest().resume == nil)
        } else {
            try await eventually { if case .error = service.connectionStates[id] { true } else { false } }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await factory.requestCount == (transient ? 2 : 1))
        await service.disconnect(accountID: id)
    }

    @Test
    func `the backoff keeps growing while every session fails its setup`() async throws {
        let transports = (0 ..< 3).map { _ in MockTransport() }
        let factory = AccountConnectionFactoryProbe(transports: transports, setupFailure: XMPPClientError.timeout)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        let attempts = OSAllocatedUnfairLock<[Int]>(initialState: [])
        service.reconnectDelay = { attempt in
            attempts.withLock { $0.append(attempt) }
            return .zero
        }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)

        let connection = Task { try await service.connect(accountID: id, password: "secret") }
        for transport in transports {
            await simulateNoTLSConnect(transport)
        }
        try await eventually { attempts.withLock { $0.count } >= 3 }

        #expect(attempts.withLock { Array($0.prefix(3)) } == [0, 1, 2])
        await service.disconnect(accountID: id)
        _ = await connection.result
    }

    @Test
    func `a replaced client's teardown leaves the attempt that replaced it alone`() async throws {
        let original = MockTransport()
        let replacement = MockTransport()
        let release = AsyncSemaphore()
        let factory = AccountConnectionFactoryProbe(transports: [original, replacement], laterRelease: release)
        let service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: factory)
        service.reconnectDelay = { _ in .zero }
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        let (_, first) = try await driveMockConnect(service, accountID: id, transport: original)
        _ = try await factory.nextRequest()

        // The new attempt waits in client construction while the client it replaces loses its connection.
        let second = Task { try await service.connect(accountID: id, password: "secret") }
        _ = try await factory.nextRequest()
        await original.simulateDisconnect()
        try await Task.sleep(for: .milliseconds(200))
        // A retry scheduled by the teardown would show the same state, but ask the factory for a third client.
        let requests = await factory.requestCount
        guard case .connecting = service.connectionStates[id], requests == 2 else {
            Issue.record("The replaced client's teardown changed the account: \(String(describing: service.connectionStates[id])), \(requests) clients")
            // Lets the replacement and any scheduled retry out of client construction.
            await release.signal()
            await release.signal()
            await service.disconnect(accountID: id)
            return
        }

        await release.signal()
        await simulateNoTLSConnect(replacement)
        try await second.value
        #expect(await factory.requestCount == 2)
        await service.disconnect(accountID: id)
        _ = await first.result
    }
}
