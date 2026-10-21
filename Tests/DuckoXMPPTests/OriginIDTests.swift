import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let contact = JID.bare(BareJID(localPart: "contact", domainPart: "example.com")!)
private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// Runs `send` against chat, room and chat-state modules set up on one stub context, returning what they sent.
private func sentMessages(
    _ send: (ChatModule, MUCModule, ChatStatesModule) async throws -> Void
) async throws -> [XMPPMessage] {
    let sent = OSAllocatedUnfairLock<[XMPPMessage]>(initialState: [])
    let context = makeStubModuleContext(sendStanza: { stanza, onAccepted in
        onAccepted?()
        sent.withLock { $0.append(XMPPMessage(element: stanza.element)) }
    })
    let chat = ChatModule()
    let muc = MUCModule()
    let chatStates = ChatStatesModule()
    chat.setUp(context)
    muc.setUp(context)
    chatStates.setUp(context)
    try await send(chat, muc, chatStates)
    return sent.withLock { $0 }
}

// MARK: - Tests

enum OriginIDTests {
    enum ContentSend: CaseIterable {
        case message, correction, retraction, roomMessage, roomPrivateMessage

        func send(chat: ChatModule, muc: MUCModule) async throws {
            switch self {
            case .message:
                try await chat.sendMessage(to: contact, body: "hi")
            case .correction:
                try await chat.sendCorrection(to: contact, body: "hi", replacingID: "orig")
            case .retraction:
                try await chat.sendRetraction(to: contact, originalID: "orig")
            case .roomMessage:
                try await muc.sendMessage(to: room, body: "hi")
            case .roomPrivateMessage:
                try await muc.sendPrivateMessage(to: room, nickname: "bob", body: "hi")
            }
        }
    }

    struct Outgoing {
        @Test(arguments: ContentSend.allCases)
        func `A content message carries its stanza ID as origin-id`(_ path: ContentSend) async throws {
            let sent = try await sentMessages { chat, muc, _ in try await path.send(chat: chat, muc: muc) }

            let message = try #require(sent.first)
            #expect(sent.count == 1)
            #expect(message.id != nil)
            #expect(message.originID == message.id)
        }

        @Test
        func `A standalone chat state carries no origin-id`() async throws {
            let sent = try await sentMessages { _, _, chatStates in try await chatStates.sendChatState(.composing, to: contact) }

            let message = try #require(sent.first)
            #expect(message.originID == nil)
        }
    }
}
