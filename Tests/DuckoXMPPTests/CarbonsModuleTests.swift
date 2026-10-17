import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(CarbonsModule())

    try await withIQOperation(client: client, operation: {
        try await client.connect(host: "example.com", port: 5222)
    }, respond: {
        await simulateNoTLSConnect(mock)
        let iqID = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:carbons:2") {
            $0.contains("<enable")
        }.id
        await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
    })

    return client
}

private func receivedCarbon(from: String?, body: String, stamp: String? = nil) -> String {
    let fromAttribute = from.map { " from='\($0)'" } ?? ""
    let delay = stamp.map { "<delay xmlns='urn:xmpp:delay' stamp='\($0)'/>" } ?? ""
    return """
    <message\(fromAttribute) to='user@example.com/ducko' type='chat'>\
    <received xmlns='urn:xmpp:carbons:2'>\
    <forwarded xmlns='urn:xmpp:forward:0'>\
    \(delay)\
    <message from='contact@example.com/res' to='user@example.com/other' type='chat'>\
    <body>\(body)</body>\
    </message>\
    </forwarded>\
    </received>\
    </message>
    """
}

// MARK: - Tests

enum CarbonsModuleTests {
    struct EnableOnConnect {
        @Test
        func `Sends enable IQ on connect`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            await disconnectFast(client)
        }

        @Test
        func `Handles enable timeout gracefully`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(CarbonsModule())

            try await withIQOperation(client: client, operation: {
                try? await client.connect(host: "example.com", port: 5222)
            }, respond: {
                await simulateNoTLSConnect(mock)
                _ = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:carbons:2") {
                    $0.contains("<enable")
                }
                // Disconnect without responding — releases the pending enable IQ.
                await disconnectFast(client)
            })

            // Disconnect resets enabled state
        }
    }

    struct ReceivedCarbon {
        @Test
        func `Parses received carbon and emits messageCarbonReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCarbonReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(receivedCarbon(
                from: "user@example.com", body: "Hello from other resource", stamp: "2026-03-01T12:00:00Z"
            ))

            let events = try await eventsTask.value
            guard case let .messageCarbonReceived(forwarded) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCarbonReceived event")
            }
            #expect(forwarded.message.body == "Hello from other resource")
            #expect(forwarded.timestamp == "2026-03-01T12:00:00Z")

            await disconnectFast(client)
        }
    }

    struct SentCarbon {
        @Test
        func `Parses sent carbon and emits messageCarbonSent`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCarbonSent = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='user@example.com' to='user@example.com/ducko' type='chat'>\
            <sent xmlns='urn:xmpp:carbons:2'>\
            <forwarded xmlns='urn:xmpp:forward:0'>\
            <message from='user@example.com/other' to='contact@example.com' type='chat'>\
            <body>Sent from other device</body>\
            </message>\
            </forwarded>\
            </sent>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCarbonSent(forwarded) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCarbonSent event")
            }
            #expect(forwarded.message.body == "Sent from other device")
            #expect(forwarded.timestamp == nil)

            await disconnectFast(client)
        }
    }

    struct Security {
        @Test(arguments: [
            (from: "evil@attacker.com", accepted: false),
            (from: "user@example.com/other", accepted: false),
            (from: "@example.com", accepted: false),
            (from: nil, accepted: true)
        ] as [(from: String?, accepted: Bool)])
        func `Accepts carbons only from the own account`(from: String?, accepted: Bool) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .messageCarbonReceived(forwarded) = event { return forwarded.message.body == "Sentinel" }
                    return false
                }
            }

            await mock.simulateReceive(receivedCarbon(from: from, body: "Probe"))
            await mock.simulateReceive(receivedCarbon(from: "user@example.com", body: "Sentinel"))

            let bodies = try await eventsTask.value.compactMap { event -> String? in
                guard case let .messageCarbonReceived(forwarded) = event else { return nil }
                return forwarded.message.body
            }
            #expect(bodies == (accepted ? ["Probe", "Sentinel"] : ["Sentinel"]))

            await disconnectFast(client)
        }
    }
}
