import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
/// Who sent the seeded message, in a room that advertises occupant ids.
private let aliceAuthor = RoomAuthorIdentity(roomSupportsOccupantIDs: true, occupantID: "occupant-alice")

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeTranscripts() -> MockTranscriptStore {
    MockTranscriptStore()
}

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

private func seedGroupchatMessage(store: MockPersistenceStore, transcripts: MockTranscriptStore) async -> UUID {
    let conversationID = UUID()
    await store.addConversation(Conversation(
        id: conversationID, accountID: testAccountID, jid: roomJID,
        type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: Date()
    ))
    let message = ChatMessage(
        id: UUID(), conversationID: conversationID, stanzaID: "msg-original",
        fromJID: "alice", roomSender: RoomSenderIdentity(aliceAuthor), body: "Original text",
        timestamp: Date(), isOutgoing: false,
        isDelivered: false, isEdited: false, type: "groupchat"
    )
    await transcripts.addMessage(message)
    return conversationID
}

// MARK: - Tests

enum ChatServiceMUCCorrectionTests {
    struct IncomingCorrection {
        @Test
        @MainActor
        func `MUC correction updates body when nickname and occupant id match`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedGroupchatMessage(store: store, transcripts: transcripts)

            let from = try #require(JID.parse("room@conference.example.com/alice"))
            await service.handleEvent(
                .messageCorrected(
                    originalID: "msg-original", newBody: "Corrected text", replyFallbackRange: nil, from: from, messageType: .groupchat, roomAuthor: aliceAuthor
                ),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Corrected text")
            #expect(messages[0].isEdited == true)
            #expect(messages[0].editedAt != nil)
        }
    }

    struct SenderVerification {
        @Test
        @MainActor
        func `MUC correction rejected when nickname does not match, even with the same occupant id`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedGroupchatMessage(store: store, transcripts: transcripts)

            let attacker = try #require(JID.parse("room@conference.example.com/bob"))
            await service.handleEvent(
                .messageCorrected(
                    originalID: "msg-original", newBody: "Hacked text", replyFallbackRange: nil, from: attacker, messageType: .groupchat, roomAuthor: aliceAuthor
                ),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
        }

        /// With `joined`, the room module recorded the occupant id its self-presence carried. Without it, the user's own
        /// occupant id is the one stored when the room last confirmed a join.
        @Test(arguments: [false, true])
        @MainActor
        func `Only the user's own occupant id corrects or retracts the user's own room message`(joined: Bool) async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            var accountID = testAccountID
            var accountService: AccountService?
            if joined {
                let transport = MockTransport()
                await transport.answerDiscoInfo(of: roomJID.description, features: [XMPPNamespaces.occupantID])
                let connected = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MUCModule()]))
                service.setAccountService(connected)
                let connectTask = Task { @MainActor in
                    try await connected.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
                }
                await simulateNoTLSConnect(transport)
                accountID = try await connectTask.value
                let muc = try #require(await connected.client(for: accountID)?.module(ofType: MUCModule.self))
                try await muc.joinRoom(roomJID, nickname: "me")
                await transport.simulateReceive(
                    "<presence from='\(roomJID)/me'><x xmlns='http://jabber.org/protocol/muc#user'>"
                        + "<item affiliation='member' role='participant'/><status code='110'/></x>"
                        + "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='occupant-me'/></presence>"
                )
                try await eventually { muc.confirmedNickname(in: roomJID) == "me" }
                accountService = connected
            }
            let conversationID = UUID()
            await store.addConversation(Conversation(
                id: conversationID, accountID: accountID, jid: roomJID, type: .groupchat, isPinned: false, isMuted: false,
                unreadCount: 0, roomNickname: joined ? nil : "me", roomOccupantID: joined ? nil : "occupant-me", createdAt: Date()
            ))
            await transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: conversationID, stanzaID: "msg-own", fromJID: "me", body: "Mine",
                timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let other = try #require(JID.parse("room@conference.example.com/bob"))
            let own = try #require(JID.parse("room@conference.example.com/me"))
            let bob = RoomAuthorIdentity(roomSupportsOccupantIDs: true, occupantID: "occupant-bob")
            let me = RoomAuthorIdentity(roomSupportsOccupantIDs: true, occupantID: "occupant-me")
            await service.handleEvent(.messageCorrected(originalID: "msg-own", newBody: "Hacked", replyFallbackRange: nil, from: other, messageType: .groupchat, roomAuthor: bob), accountID: accountID)
            await service.handleEvent(.messageRetracted(originalID: "msg-own", from: other, messageType: .groupchat, roomAuthor: bob), accountID: accountID)
            // Armed: the user's own correction goes through with the user's occupant id.
            await service.handleEvent(.messageCorrected(originalID: "msg-own", newBody: "Fixed", replyFallbackRange: nil, from: own, messageType: .groupchat, roomAuthor: me), accountID: accountID)

            let amendments = await transcripts.amendments.map(\.amendment)
            #expect(amendments.map(\.action) == [.edit])
            #expect(amendments.map(\.body) == ["Fixed"])
            if let accountService {
                await accountService.disconnect(accountID: accountID)
            }
        }

        @Test
        @MainActor
        func `MUC correction rejected when from is bare JID`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let conversationID = await seedGroupchatMessage(store: store, transcripts: transcripts)

            let bareFrom = JID.bare(roomJID)
            await service.handleEvent(
                .messageCorrected(
                    originalID: "msg-original", newBody: "Spoofed text", replyFallbackRange: nil, from: bareFrom, messageType: .groupchat, roomAuthor: aliceAuthor
                ),
                accountID: testAccountID
            )

            let messages = try await transcripts.fetchMessages(for: conversationID, before: nil, limit: 50)
            #expect(messages[0].body == "Original text")
            #expect(messages[0].isEdited == false)
        }
    }
}
