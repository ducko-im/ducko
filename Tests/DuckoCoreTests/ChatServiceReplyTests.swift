import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

// MARK: - Tests

enum ChatServiceReplyTests {
    struct IncomingReply {
        @Test
        @MainActor
        func `Incoming message with reply element sets replyToID`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID), id: "reply-msg-1")
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "This is a reply"
            let replyElement = XMLElement(
                name: "reply",
                namespace: XMPPNamespaces.messageReply,
                attributes: ["to": "contact@example.com", "id": "original-msg-1"]
            )
            xmppMessage.element.addChild(replyElement)

            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].replyToID == "original-msg-1")
            #expect(messages[0].body == "This is a reply")
        }

        @Test
        @MainActor
        func `Incoming message without reply element has nil replyToID`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let service = makeChatService(store: store, transcripts: transcripts)

            var xmppMessage = XMPPMessage(type: .chat, to: .bare(testAccountJID), id: "plain-msg-1")
            xmppMessage.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "res")))
            xmppMessage.body = "Just a normal message"

            await service.handleEvent(.messageReceived(xmppMessage), accountID: testAccountID)

            let conversations = try await store.fetchConversations(for: testAccountID)
            let messages = try await transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
            #expect(messages[0].replyToID == nil)
        }
    }
}

@MainActor
extension ChatServiceReplyTests {
    @Test(arguments: [false, true])
    static func `live stanza metadata survives transcript reopening`(hasReply: Bool) async throws {
        try await verifyPersistedInboundMetadata(origin: .live, hasReply: hasReply)
    }
}
