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
    await client.register(ChatModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ChatModuleMessageTypeTests {
    struct NormalCorrection {
        @Test
        func `Normal message correction emits messageCorrected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='normal' id='msg-2'>\
            <body>Hello (corrected)</body>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCorrected(originalID, newBody, _, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCorrected")
            }
            #expect(originalID == "msg-1")
            #expect(newBody == "Hello (corrected)")
            #expect(messageType == .normal)
            #expect(from.bareJID.description == "contact@example.com")

            await disconnectFast(client)
        }
    }

    struct NormalRetraction {
        @Test
        func `Normal message retraction emits messageRetracted`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageRetracted = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='normal' id='retract-1'>\
            <retract xmlns='urn:xmpp:message-retract:1' id='msg-1'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageRetracted(originalID, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageRetracted")
            }
            #expect(originalID == "msg-1")
            #expect(from.bareJID.description == "contact@example.com")
            #expect(messageType == .normal)

            await disconnectFast(client)
        }
    }

    struct HeadlineExcluded {
        @Test
        func `Headline message is not processed by ChatModule`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Send a headline with a correction — should NOT emit messageCorrected
            await mock.simulateReceive("""
            <message from='server@example.com' to='user@example.com/ducko' type='headline' id='h-1'>\
            <body>Server alert</body>\
            <replace xmlns='urn:xmpp:message-correct:0' id='old-1'/>\
            </message>
            """)
            try? await Task.sleep(for: .milliseconds(200))

            // Send a chat message to flush the stream
            await mock.simulateReceive("""
            <message from='other@example.com/res' to='user@example.com/ducko' type='chat' id='flush'>\
            <body>flush</body>\
            </message>
            """)

            let events = try await collectEvents(from: client) { event in
                if case .messageReceived = event { return true }
                return false
            }

            let hasCorrected = events.contains { event in
                if case .messageCorrected = event { return true }
                return false
            }
            #expect(!hasCorrected)

            await disconnectFast(client)
        }
    }
}
