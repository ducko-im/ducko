import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(
    mock: MockTransport, pingInterval: Duration = .milliseconds(200), pingTimeout: Duration = .seconds(30)
) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(PingModule(pingInterval: pingInterval, pingTimeout: pingTimeout))

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum PingModuleTests {
    struct IncomingPing {
        @Test
        func `Responds to incoming ping IQ with result`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive(
                "<iq type='get' from='example.com' id='ping-1'><ping xmlns='urn:xmpp:ping'/></iq>"
            )

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pongIQ = sentStrings.first { $0.contains("id=\"ping-1\"") && $0.contains("type=\"result\"") }
            #expect(pongIQ != nil)
            #expect(pongIQ?.contains("to=\"example.com\"") == true)

            await disconnectFast(client)
        }
    }

    struct Keepalive {
        @Test
        func `Sends keepalive pings on interval`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            // Wait for at least one keepalive ping
            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pingIQ = sentStrings.first { $0.contains("<ping") && $0.contains("urn:xmpp:ping") }
            #expect(pingIQ != nil)

            // Respond to avoid timeout blocking
            if let iqStr = pingIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            await disconnectFast(client)
        }

        @Test
        func `Stops keepalive on disconnect`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await disconnectFast(client)
            await mock.clearSentBytes()

            // Wait longer than the keepalive interval
            try? await Task.sleep(for: .milliseconds(350))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let pingIQ = sentStrings.first { $0.contains("<ping") && $0.contains("urn:xmpp:ping") }
            #expect(pingIQ == nil)
        }

        @Test
        func `An unanswered keepalive ping ends the session as lost`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock, pingTimeout: .milliseconds(200))

            let events = try await collectEvents(from: client) { if case .disconnected = $0 { true } else { false } }

            guard case .disconnected(.connectionLost)? = events.last else {
                Issue.record("Expected a lost connection, got \(events)")
                return
            }
        }

        @Test
        func `A keepalive ping answered with an error keeps the session`() async throws {
            let mock = MockTransport()
            await mock.autoReply(answeringPings(type: "error"))
            let client = try await makeConnectedClient(mock: mock, pingTimeout: .milliseconds(200))

            // Two keepalive rounds, each long enough for an unanswered ping to time out.
            try await Task.sleep(for: .milliseconds(900))

            #expect(await client.acceptsStanzas)
            await disconnectFast(client)
        }
    }

    struct Liveness {
        @Test
        func `An unanswered liveness check ends the session within its timeout`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock, pingInterval: .seconds(300))
            let ping = try #require(await client.module(ofType: PingModule.self))
            let events = Task { try await collectEvents(from: client, timeout: .seconds(1)) { if case .disconnected = $0 { true } else { false } } }

            await ping.checkLiveness(timeout: .milliseconds(200))

            guard case .disconnected(.connectionLost)? = try await events.value.last else {
                Issue.record("Expected a lost connection")
                return
            }
        }

        @Test
        func `An answered liveness check keeps the session`() async throws {
            let mock = MockTransport()
            await mock.autoReply(answeringPings(type: "result"))
            let client = try await makeConnectedClient(mock: mock, pingInterval: .seconds(300))
            let ping = try #require(await client.module(ofType: PingModule.self))

            await ping.checkLiveness(timeout: .milliseconds(200))

            #expect(await client.acceptsStanzas)
            await disconnectFast(client)
        }

        @Test
        func `A ping whose request times out before the check does ends the session`() async {
            let reports = OSAllocatedUnfairLock<[String]>(initialState: [])
            let ping = PingModule()
            ping.setUp(makeStubModuleContext(
                sendIQ: { _, _ in throw XMPPClientError.timeout },
                reportConnectionLost: { detail in reports.withLock { $0.append(detail) } }
            ))

            await ping.checkLiveness(timeout: .seconds(30))

            #expect(reports.withLock { $0 } == ["The server stopped responding"])
        }
    }
}

/// Answers each ping the client sends with an IQ of `type`.
private func answeringPings(type: String) -> @Sendable (String) -> String? {
    { stanza in
        guard stanza.contains(XMPPNamespaces.ping), let id = extractIQID(from: stanza) else { return nil }
        let error = type == "error" ? "<error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>" : ""
        return "<iq type='\(type)' id='\(id)' from='example.com'>\(error)</iq>"
    }
}
