import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    await client.register(ReceiptsModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ReceiptsModuleTests {
    struct AutoReply {
        @Test
        func `Auto-replies with receipt for chat message with body and request`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let receiptReply = await awaitSentResponse(
                on: mock,
                afterReceiving: """
                <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-1'>\
                <body>Hello</body>\
                <request xmlns='urn:xmpp:receipts'/>\
                </message>
                """,
                matching: {
                    $0.contains("urn:xmpp:receipts") && $0.contains("<received") && $0.contains("id=\"msg-1\"")
                }
            )
            #expect(receiptReply != nil)

            await disconnectFast(client)
        }

        @Test
        func `Does not auto-reply for groupchat messages`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Short observation budget: negative cases only need enough time to
            // rule out the fire-and-forget response; a 2 s default would add
            // seconds of slack to every run.
            let receiptReply = await awaitSentResponse(
                on: mock,
                afterReceiving: """
                <message from='room@example.com/nick' to='user@example.com/ducko' type='groupchat' id='msg-2'>\
                <body>Hello room</body>\
                <request xmlns='urn:xmpp:receipts'/>\
                </message>
                """,
                matching: {
                    $0.contains("urn:xmpp:receipts") && $0.contains("<received") && $0.contains("id=\"msg-2\"")
                },
                timeout: .milliseconds(200)
            )
            #expect(receiptReply == nil)

            await disconnectFast(client)
        }

        @Test
        func `Does not auto-reply for messages without body`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let receiptReply = await awaitSentResponse(
                on: mock,
                afterReceiving: """
                <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-3'>\
                <request xmlns='urn:xmpp:receipts'/>\
                </message>
                """,
                matching: {
                    $0.contains("urn:xmpp:receipts") && $0.contains("<received") && $0.contains("id=\"msg-3\"")
                },
                timeout: .milliseconds(200)
            )
            #expect(receiptReply == nil)

            await disconnectFast(client)
        }

        /// A legacy OMEMO message encrypts only its body, so what stands next to it could be anyone's. Only what its
        /// decrypted copy keeps counts: a receipt request or a marker request.
        @Test
        func `Neither answers nor reports what stands next to a legacy OMEMO payload`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .deliveryReceiptReceived(messageID, _) = event { messageID == "next" } else { false }
                }
            }

            let receiptReply = await awaitSentResponse(
                on: mock,
                afterReceiving: """
                <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-4'>\
                <body>I sent you an OMEMO encrypted message</body>\
                <request xmlns='urn:xmpp:receipts'/>\
                <received xmlns='urn:xmpp:receipts' id='original-msg'/>\
                <displayed xmlns='urn:xmpp:chat-markers:0' id='original-msg'/>\
                <encrypted xmlns='\(XMPPNamespaces.omemoLegacy)'><header sid='1'><iv>AAAA</iv></header><payload>AAAA</payload></encrypted>\
                </message>
                """,
                matching: { $0.contains("<received") && $0.contains("id=\"msg-4\"") },
                timeout: .milliseconds(200)
            )
            await mock.simulateReceive("<message from='contact@example.com/res' type='chat'><received xmlns='urn:xmpp:receipts' id='next'/></message>")

            #expect(receiptReply == nil)
            let events = try await eventsTask.value
            #expect(!events.contains { if case .chatMarkerReceived = $0 { true } else { false } })
            #expect(events.count { if case .deliveryReceiptReceived = $0 { true } else { false } } == 1)

            await disconnectFast(client)
        }
    }

    struct ReceiptReceived {
        @Test
        func `Emits deliveryReceiptReceived when receipt arrives`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .deliveryReceiptReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <received xmlns='urn:xmpp:receipts' id='original-msg'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .deliveryReceiptReceived(messageID, from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected deliveryReceiptReceived")
            }
            #expect(messageID == "original-msg")
            #expect(from.bareJID.description == "contact@example.com")

            await disconnectFast(client)
        }
    }

    struct ChatMarkers {
        @Test
        func `Emits chatMarkerReceived for displayed marker`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .chatMarkerReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat'>\
            <displayed xmlns='urn:xmpp:chat-markers:0' id='msg-42'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .chatMarkerReceived(messageID, markerType, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected chatMarkerReceived")
            }
            #expect(messageID == "msg-42")
            #expect(markerType == .displayed)

            await disconnectFast(client)
        }
    }
}
