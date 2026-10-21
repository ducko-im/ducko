import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeClient(mock: MockTransport, requiresSCRAM: Bool = false) -> XMPPClient {
    XMPPClient(
        domain: "example.com", credentials: .init(username: "user", password: "pencil"), transport: mock,
        requireTLS: false, requiresSCRAM: requiresSCRAM
    )
}

/// SASL2 features offering only SCRAM-SHA-256, with Bind 2.
private let scramSASL2Features = """
<features xmlns='http://etherx.jabber.org/streams'>\
<authentication xmlns='urn:xmpp:sasl:2'><mechanism>SCRAM-SHA-256</mechanism>\
<inline><bind xmlns='urn:xmpp:bind:0'/></inline></authentication>\
</features>
"""

private func isPlainSignInRefused(_ event: XMPPEvent) -> Bool {
    if case .plainSignInRefused = event { return true }
    return false
}

// MARK: - Tests

enum XMPPClientSignInSecurityTests {
    struct Refusal {
        @Test
        func `With SCRAM required, a SASL1 offer of only PLAIN is refused before any auth is sent`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock, requiresSCRAM: true)
            let events = Task { try await collectEvents(from: client, until: isPlainSignInRefused) }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesNoTLS)

            let error = try await boundedFailure(of: connectTask)
            guard case .plainSignInRefused = error as? XMPPClientError else {
                Issue.record("Expected plainSignInRefused, got \(String(describing: error))")
                await disconnectFast(client)
                return
            }
            #expect(try await events.value.contains(where: isPlainSignInRefused))
            #expect(await mock.sentBytes.count == 1)
            #expect(await !(mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<auth") }))
        }

        @Test
        func `With SCRAM required, a SASL2 offer of only PLAIN is refused before any authenticate is sent`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock, requiresSCRAM: true)

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testSASL2Features(bind2Inline: []))

            let error = try await boundedFailure(of: connectTask)
            guard case .plainSignInRefused = error as? XMPPClientError else {
                Issue.record("Expected plainSignInRefused, got \(String(describing: error))")
                await disconnectFast(client)
                return
            }
            #expect(await mock.sentBytes.count == 1)
            #expect(await !(mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<authenticate") }))
        }
    }

    struct VerifiedSCRAM {
        @Test
        func `A verified SCRAM success is recorded even when binding then fails`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock)
            var server = SCRAMTestServer(password: "pencil")

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            try await server.playSASL1SignIn(on: mock)
            await mock.waitForSent(count: 4) // post-auth stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(testFeaturesBind)
            await mock.waitForSent(count: 5) // bind IQ
            await mock.simulateReceive("<iq type='error' id='bind'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")

            await #expect(throws: XMPPClientError.self) { try await connectTask.value }
            #expect(client.verifiedSCRAMMechanism == SCRAMTestServer.mechanism)
        }

        @Test
        func `A SCRAM success whose signature does not check out records nothing`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock)
            var server = SCRAMTestServer(password: "not the password")

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            try await server.playSASL1SignIn(on: mock)

            await #expect(throws: XMPPClientError.self) { try await connectTask.value }
            #expect(client.verifiedSCRAMMechanism == nil)
        }

        @Test
        func `A PLAIN sign-in records nothing`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            #expect(client.verifiedSCRAMMechanism == nil)
            await disconnectFast(client)
        }

        @Test
        func `A verified SASL2 SCRAM success is recorded even when the rest of the success reply is unusable`() async throws {
            let mock = MockTransport()
            let client = makeClient(mock: mock)
            var server = SCRAMTestServer(password: "pencil")

            let connectTask = Task { try await client.connectWithTLS(host: "example.com", port: 5223) }
            await mock.waitForSent(count: 1) // stream opening
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive(scramSASL2Features)
            let authenticate = try #require(await mock.waitForSent { $0.hasPrefix("<authenticate ") })
            let serverFirst = try server.serverFirst(answering: #require(SCRAMTestServer.payload(in: authenticate)))
            await mock.simulateReceive("<challenge xmlns='urn:xmpp:sasl:2'>\(serverFirst)</challenge>")
            let response = try #require(await mock.waitForSent { $0.hasPrefix("<response ") })
            let serverFinal = try server.serverFinal(answering: #require(SCRAMTestServer.payload(in: response)))
            // No authorization identifier, so the success names no session.
            await mock.simulateReceive("<success xmlns='urn:xmpp:sasl:2'><additional-data>\(serverFinal)</additional-data></success>")

            await #expect(throws: XMPPClientError.self) { try await connectTask.value }
            #expect(client.verifiedSCRAMMechanism == SCRAMTestServer.mechanism)
        }
    }
}
