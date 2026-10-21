import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// A client connected over `mock` that has joined `room@conference.example.com` as `me`.
private func makeJoinedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com", credentials: .init(username: "user", password: "pass"), transport: mock, requireTLS: false
    )
    await client.register(ChatModule())
    await client.register(MUCModule())
    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value
    let module = try #require(await client.module(ofType: MUCModule.self))
    try await module.joinRoom(#require(BareJID.parse("room@conference.example.com")), nickname: "me")
    return client
}

/// The ids of the room and private messages reported until the one with id `last`.
private func reportedMessageIDs(from client: XMPPClient, until last: String) -> Task<[String], any Error> {
    Task {
        let events = try await collectEvents(from: client) { event in
            switch event {
            case let .roomMessageReceived(message), let .mucPrivateMessageReceived(message): message.id == last
            default: false
            }
        }
        return events.compactMap { event in
            switch event {
            case let .roomMessageReceived(message), let .mucPrivateMessageReceived(message): message.id
            default: nil
            }
        }
    }
}

/// What the room module reports, each as its kind and the id it names, until the room message with id `last`.
private func reportedRoomEvents(from client: XMPPClient, until last: String) -> Task<[String], any Error> {
    Task {
        let events = try await collectEvents(from: client) { event in
            if case let .roomMessageReceived(message) = event { message.id == last } else { false }
        }
        return events.compactMap { event in
            switch event {
            case let .roomMessageReceived(message): "message \(message.id ?? "")"
            case .roomSubjectChanged: "subject"
            case let .roomInviteReceived(invite): "invite \(invite.room)"
            case let .messageCorrected(originalID, _, _, _, _): "corrected \(originalID)"
            case let .messageRetracted(originalID, _, _): "retracted \(originalID)"
            default: nil
            }
        }
    }
}

private let nextRoomMessage = "<message type='groupchat' from='room@conference.example.com/alice' id='next'><body>Next</body></message>"

// MARK: - Tests

/// What a room and its private chats report of an encrypted message: an OMEMO one is left to `OMEMOModule`, and any
/// other is reported so its notice can show. Nothing next to its payload is taken as part of it.
struct MUCModuleEncryptionTests {
    @Test func `an OMEMO private message is not reported with the body and file link next to its payload`() async throws {
        let mock = MockTransport()
        let client = try await makeJoinedClient(mock: mock)
        let eventsTask = reportedMessageIDs(from: client, until: "pm-2")

        await mock.simulateReceive("""
        <message type='chat' from='room@conference.example.com/alice' id='pm-1'>\
        <body>injected</body>\
        <x xmlns='jabber:x:oob'><url>https://example.com/injected.png</url></x>\
        <encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/><payload>AAAA</payload></encrypted>\
        </message>
        """)
        await mock.simulateReceive("<message type='chat' from='room@conference.example.com/alice' id='pm-2'><body>Next</body></message>")

        #expect(try await eventsTask.value == ["pm-2"])
        await disconnectFast(client)
    }

    @Test func `a room message encrypted with another method is reported without a body`() async throws {
        let mock = MockTransport()
        let client = try await makeJoinedClient(mock: mock)
        let eventsTask = reportedMessageIDs(from: client, until: "r-1")

        await mock.simulateReceive("""
        <message type='groupchat' from='room@conference.example.com/alice' id='r-1'>\
        <encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:openpgp:0'/>\
        <openpgp xmlns='urn:xmpp:openpgp:0'>AAAA</openpgp>\
        </message>
        """)

        #expect(try await eventsTask.value == ["r-1"])
        await disconnectFast(client)
    }

    enum ClearChild: String, CaseIterable {
        case subject, mediatedInvite, directInvite

        /// A message carrying this child in the clear next to an OMEMO payload.
        var stanza: String {
            let payload = "<encrypted xmlns='\(XMPPNamespaces.omemo)'><header sid='1'/><payload>AAAA</payload></encrypted>"
            return switch self {
            case .subject:
                "<message type='groupchat' from='room@conference.example.com/alice' id='e-1'><subject>Injected</subject>\(payload)</message>"
            case .mediatedInvite:
                """
                <message from='room@conference.example.com' id='e-1'>\
                <x xmlns='\(XMPPNamespaces.mucUser)'><invite from='eve@example.com/res'/></x>\(payload)</message>
                """
            case .directInvite:
                "<message from='eve@example.com/res' id='e-1'><x xmlns='\(XMPPNamespaces.mucDirectInvite)' jid='other@conference.example.com'/>\(payload)</message>"
            }
        }
    }

    /// The children next to an encrypted payload are outside the encryption (XEP-0420).
    @Test(arguments: ClearChild.allCases)
    func `a subject or invite in the clear next to an OMEMO payload is not taken`(child: ClearChild) async throws {
        let mock = MockTransport()
        let client = try await makeJoinedClient(mock: mock)
        let eventsTask = reportedRoomEvents(from: client, until: "next")

        await mock.simulateReceive(child.stanza)
        await mock.simulateReceive(nextRoomMessage)

        #expect(try await eventsTask.value == ["message next"])
        await disconnectFast(client)
    }

    /// An EME message's body is at most the sender's fallback text (XEP-0380), and an amendment next to it is outside its
    /// encryption.
    @Test(arguments: [
        "<replace xmlns='\(XMPPNamespaces.messageCorrect)' id='m-1'/>",
        "<retract xmlns='\(XMPPNamespaces.messageRetract)' id='m-1'/>"
    ])
    func `a room message encrypted with another method is reported for its notice, never as an amendment`(amendment: String) async throws {
        let mock = MockTransport()
        let client = try await makeJoinedClient(mock: mock)
        let eventsTask = reportedRoomEvents(from: client, until: "next")

        await mock.simulateReceive("""
        <message type='groupchat' from='room@conference.example.com/alice' id='r-1'>\
        <body>This message is encrypted with OpenPGP</body>\(amendment)\
        <encryption xmlns='\(XMPPNamespaces.eme)' namespace='urn:xmpp:openpgp:0'/>\
        </message>
        """)
        await mock.simulateReceive(nextRoomMessage)

        #expect(try await eventsTask.value == ["message r-1", "message next"])
        await disconnectFast(client)
    }

    @Test func `a room message naming OMEMO without its payload is reported for its notice`() async throws {
        let mock = MockTransport()
        let client = try await makeJoinedClient(mock: mock)
        let eventsTask = reportedRoomEvents(from: client, until: "next")

        await mock.simulateReceive("""
        <message type='groupchat' from='room@conference.example.com/alice' id='r-1'>\
        <encryption xmlns='\(XMPPNamespaces.eme)' namespace='\(XMPPNamespaces.omemo)'/>\
        </message>
        """)
        await mock.simulateReceive(nextRoomMessage)

        #expect(try await eventsTask.value == ["message r-1", "message next"])
        await disconnectFast(client)
    }
}
