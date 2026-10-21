import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// The room the user joined as `me`, holding the user's own message `m1` as it was stored when sent: without a server ID.
@MainActor
private struct RoomWithOwnMessage {
    let store = MockPersistenceStore()
    let conversation = Conversation(
        id: UUID(), accountID: testAccountID, jid: testRoomJID, type: .groupchat,
        isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
    )

    var ownMessage: ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversation.id, stanzaID: "m1", fromJID: testRoomJID.description,
            body: "Hello room", timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
        )
    }

    func makeChatService(transcripts: any TranscriptStore) -> ChatService {
        ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
    }
}

/// The room's echo of `m1` under a message id the room chose, stamped with the stanza-id `srv-1` by `stampedBy`.
private func ownEcho(stampedBy: String) -> XMPPMessage {
    var message = XMPPMessage(type: .groupchat, to: .bare(testAccountJID), id: "restamped")
    message.from = .full(FullJID(bareJID: testRoomJID, resourcePart: "me")!)
    message.body = "Hello room"
    message.element.addChild(DuckoXMPP.XMLElement(name: "origin-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "m1"]))
    message.element.addChild(DuckoXMPP.XMLElement(
        name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "srv-1", "by": stampedBy]
    ))
    return message
}

struct ChatServiceOwnRoomEchoTests {
    @Test(arguments: [(testRoomJID.description, "srv-1"), ("other@example.com", nil)])
    @MainActor
    func `The room's echo records the room's stanza-id on the user's own message`(stampedBy: String, recorded: String?) async throws {
        let room = RoomWithOwnMessage()
        await room.store.addConversation(room.conversation)
        let transcripts = MockTranscriptStore()
        await transcripts.addMessage(room.ownMessage)
        let service = room.makeChatService(transcripts: transcripts)

        await service.handleEvent(.roomMessageReceived(ownEcho(stampedBy: stampedBy)), accountID: testAccountID)

        let messages = try await transcripts.fetchMessages(for: room.conversation.id, before: nil, limit: 50)
        #expect(messages.map(\.serverID) == [recorded])
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Moderation by the recorded stanza-id retracts the user's own message`(coldIndex: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let room = RoomWithOwnMessage()
            await room.store.addConversation(room.conversation)
            let ownMessage = room.ownMessage
            let echoTranscripts = FileTranscriptStore(baseDirectory: directory)
            try await echoTranscripts.appendMessage(ownMessage)
            await room.makeChatService(transcripts: echoTranscripts)
                .handleEvent(.roomMessageReceived(ownEcho(stampedBy: testRoomJID.description)), accountID: testAccountID)

            // A fresh store knows the recorded stanza-id only from the files.
            let transcripts = coldIndex ? FileTranscriptStore(baseDirectory: directory) : echoTranscripts
            await room.makeChatService(transcripts: transcripts).handleEvent(
                .messageModerated(originalID: "srv-1", moderator: "admin", room: testRoomJID, reason: nil),
                accountID: testAccountID
            )

            let moderated = try await transcripts.findMessage(serverID: "srv-1", conversationID: room.conversation.id)
            #expect(moderated?.id == ownMessage.id)
            #expect(moderated?.isRetracted == true)
        }
    }
}
