import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
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

enum ChatModuleCorrectionTests {
    struct IncomingCorrection {
        @Test
        func `Emits messageCorrected for incoming correction`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-2'>\
            <body>Hello (corrected)</body>\
            <replace xmlns='urn:xmpp:message-correct:0' id='msg-1'/>\
            <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='6'/></fallback>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageCorrected(originalID, newBody, replyFallbackRange, from, messageType) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageCorrected")
            }
            #expect(originalID == "msg-1")
            #expect(newBody == "Hello (corrected)")
            #expect(replyFallbackRange == 0 ..< 6)
            #expect(messageType == .chat)
            #expect(from.bareJID.description == "contact@example.com")

            await disconnectFast(client)
        }

        /// The message shows only its notice, and the amendment next to it is outside its encryption (XEP-0380).
        @Test(arguments: [
            "<replace xmlns='\(XMPPNamespaces.messageCorrect)' id='msg-1'/>",
            "<retract xmlns='\(XMPPNamespaces.messageRetract)' id='msg-1'/>"
        ])
        func `Reports no amendment next to a message encrypted with another method`(amendment: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageCorrected(originalID: "msg-next", _, _, _, _) = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-2'>\
            <body>This message is encrypted with OpenPGP</body>\(amendment)\
            <encryption xmlns='\(XMPPNamespaces.eme)' namespace='urn:xmpp:openpgp:0'/>\
            </message>
            """)
            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='chat' id='msg-3'>\
            <body>Next</body><replace xmlns='\(XMPPNamespaces.messageCorrect)' id='msg-next'/>\
            </message>
            """)

            let amended = try await eventsTask.value.compactMap { event -> String? in
                switch event {
                case let .messageCorrected(originalID, _, _, _, _), let .messageRetracted(originalID, _, _): originalID
                default: nil
                }
            }
            #expect(amended == ["msg-next"])

            await disconnectFast(client)
        }
    }

    struct SendCorrection {
        @Test
        func `Sends correction XML with replace element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ChatModule.self))

            await mock.clearSentBytes()

            let recipient = try #require(JID.parse("contact@example.com"))
            try await module.sendCorrection(to: recipient, body: "Fixed text", replacingID: "orig-1")

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let correctionMsg = sentStrings.first {
                $0.contains("<replace") && $0.contains("urn:xmpp:message-correct:0") && $0.contains("id=\"orig-1\"")
            }
            #expect(correctionMsg != nil)
            if let msg = correctionMsg {
                #expect(msg.contains("Fixed text"))
            }

            await disconnectFast(client)
        }
    }

    struct SendReply {
        @Test
        func `Sends the reply after a quote its fallback marks`() async throws {
            let sent = OSAllocatedUnfairLock<[XMPPMessage]>(initialState: [])
            let module = ChatModule()
            module.setUp(makeStubModuleContext(sendStanza: { stanza, onAccepted in
                onAccepted?()
                sent.withLock { $0.append(XMPPMessage(element: stanza.element)) }
            }))
            let author = try #require(JID.parse("contact@example.com/phone"))
            let reply = MessageReply(to: "quoted-1", by: author, quoting: "First line\nSecond")

            try await module.sendMessage(to: author, body: reply.body(replying: "Reply text"), additionalElements: reply.elements)

            let message = try #require(sent.withLock { $0.first })
            let replyElement = try #require(message.element.child(named: "reply", namespace: XMPPNamespaces.messageReply))
            #expect(replyElement.attribute("id") == "quoted-1")
            #expect(replyElement.attribute("to") == "contact@example.com/phone")
            #expect(message.body == "> First line\n> Second\nReply text")
            let fallback = try #require(message.fallbackIndication(for: XMPPNamespaces.messageReply))
            #expect(fallback.bodyRange == 0 ..< 22)
        }

        @Test
        func `Declares the reply feature`() {
            #expect(ChatModule().features.contains(XMPPNamespaces.messageReply))
        }
    }

    struct MessageError {
        @Test
        func `Emits messageError for error-type message`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .messageError = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='contact@example.com/res' to='user@example.com/ducko' type='error' id='msg-err'>\
            <error type='cancel'>\
            <service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>\
            </error>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .messageError(messageID, from, error) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected messageError")
            }
            #expect(messageID == "msg-err")
            #expect(from.bareJID.description == "contact@example.com")
            #expect(error.condition == .serviceUnavailable)

            await disconnectFast(client)
        }
    }
}
