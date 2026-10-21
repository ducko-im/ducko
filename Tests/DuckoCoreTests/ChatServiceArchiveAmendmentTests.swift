import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// A groupchat message as the room's archive returns it, known to the archive as `arch-<id>`. Without `nick` it comes
/// from the room itself.
private struct RoomEntry {
    var nick: String? = "bob"
    let id: String
    var serverID: String?
    let stamp: String
    var body: String?
    var payload = ""

    func xml(queryID: String) -> String {
        let from = nick.map { "\(roomJID)/\($0)" } ?? roomJID.description
        let stanzaID = serverID.map { "<stanza-id xmlns='urn:xmpp:sid:0' id='\($0)' by='\(roomJID)'/>" } ?? ""
        return "<message from='\(roomJID)'>"
            + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='arch-\(id)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'>"
            + "<delay xmlns='urn:xmpp:delay' stamp='2026-02-28T\(stamp)Z'/>"
            + "<message from='\(from)' type='groupchat' id='\(id)'>"
            + (body.map { "<body>\($0)</body>" } ?? "")
            + payload + stanzaID
            + "</message></forwarded></result></message>"
    }

    static func original(_ id: String, serverID: String, body: String, at stamp: String) -> RoomEntry {
        RoomEntry(id: id, serverID: serverID, stamp: stamp, body: body)
    }

    static func correction(_ id: String, of originalID: String, body: String, at stamp: String) -> RoomEntry {
        RoomEntry(
            id: id, stamp: stamp, body: body,
            payload: "<replace xmlns='urn:xmpp:message-correct:0' id='\(originalID)'/>"
        )
    }
}

/// A chat service connected to an archive, with the room `roomJID` stored, in which the user is `alice`.
@MainActor
private struct ArchiveHarness {
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let room: Conversation
    let accountID: UUID

    static func connect() async throws -> ArchiveHarness {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let transport = MockTransport()
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MAMModule()]))
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let accountID = try await connectTask.value
        let room = Conversation(
            id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
            isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "alice", createdAt: Date()
        )
        try await store.upsertConversation(room)
        return ArchiveHarness(
            transcripts: transcripts, transport: transport, accountService: accountService,
            chatService: chatService, room: room, accountID: accountID
        )
    }

    func fetchHistory() -> Task<(messages: [ChatMessage], hasMore: Bool), any Error> {
        Task { @MainActor in
            try await chatService.fetchServerHistory(jid: roomJID, accountID: accountID, before: nil, limit: 50)
        }
    }

    /// Answers the next archive query with `entries` as one page, whose `fin` names its first entry.
    func answerNextQuery(with entries: [RoomEntry], complete: Bool, answered: inout Set<String>) async throws {
        let query = try await nextArchiveQuery(on: transport, answered: &answered)
        for entry in entries {
            await transport.simulateReceive(entry.xml(queryID: query.queryID))
        }
        let first = entries.first.map { "<first>arch-\($0.id)</first>" } ?? ""
        await transport.simulateReceive(
            "<iq type='result' id='\(query.iqID)' from='\(roomJID)'>"
                + "<fin xmlns='urn:xmpp:mam:2'\(complete ? " complete='true'" : "")>"
                + "<set xmlns='http://jabber.org/protocol/rsm'>\(first)</set></fin></iq>"
        )
    }

    func storedMessages() async throws -> [ChatMessage] {
        try await transcripts.fetchMessages(for: room.id, before: nil, limit: 50)
    }

    func addMessage(_ id: String, serverID: String, body: String) async {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: room.id, stanzaID: id, serverID: serverID, fromJID: "bob", body: body,
            timestamp: Date(timeIntervalSince1970: 1_772_272_800), isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat"
        ))
    }
}

struct ChatServiceArchiveAmendmentTests {
    @Test(arguments: [false, true])
    @MainActor
    func `A correction on the page of its message applies in either order`(correctionFirst: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let original = RoomEntry.original("m1", serverID: "R1", body: "helo", at: "10:00:00")
        let correction = RoomEntry.correction("m2", of: "m1", body: "hello", at: "10:01:00")

        try await harness.answerNextQuery(with: correctionFirst ? [correction, original] : [original, correction], complete: true, answered: &answered)

        let (messages, _) = try await fetch.value
        #expect(messages.map(\.body) == ["hello"])
        let stored = try await harness.storedMessages()
        #expect(stored.map(\.body) == ["hello"])
        #expect(stored.first?.isEdited == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test
    @MainActor
    func `A correction on the newest page is applied once the pages back reach its message`() async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.correction("m9", of: "m1", body: "hello", at: "10:09:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.original("m5", serverID: "R5", body: "between", at: "10:05:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "helo", at: "10:00:00")], complete: false, answered: &answered
        )

        let (messages, hasMore) = try await fetch.value
        #expect(messages.map(\.body) == ["hello", "between"])
        #expect(hasMore)
        #expect(answered.count == 3)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Of the corrections of one message the newest text stays`(liveCorrectionFirst: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        await harness.addMessage("m1", serverID: "R1", body: "helo")
        if liveCorrectionFirst {
            let bob = try JID.full(#require(FullJID(bareJID: roomJID, resourcePart: "bob")))
            await harness.chatService.handleEvent(
                .messageCorrected(originalID: "m1", newBody: "hello at last", replyFallbackRange: nil, from: bob, messageType: .groupchat), accountID: harness.accountID
            )
        }
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.correction("m3", of: "m1", body: "hello again", at: "10:02:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.correction("m2", of: "m1", body: "hello", at: "10:01:00")], complete: true, answered: &answered
        )

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.body) == [liveCorrectionFirst ? "hello at last" : "hello again"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `An archived retraction removes its message and is never shown`(byModerator: Bool) async throws {
        let retraction = byModerator
            ? RoomEntry(
                nick: nil, id: "m2", stamp: "10:01:00", body: "A moderator removed a message",
                payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'>"
                    + "<moderated xmlns='urn:xmpp:message-moderate:1' by='\(roomJID)/mod'/></retract>"
            )
            : RoomEntry(id: "m2", stamp: "10:01:00", body: "bob retracted a message", payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'/>")
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "oops", at: "10:00:00"), retraction], complete: true, answered: &answered
        )

        _ = try await fetch.value
        let stored = try await harness.storedMessages()
        #expect(stored.count == 1)
        #expect(stored.first?.isRetracted == true)
        #expect(stored.first?.body == "")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Only the room itself moderates (XEP-0425), so an occupant's claim to have moderated bob's message changes nothing.
    @Test
    @MainActor
    func `An archived moderation from an occupant leaves the message`() async throws {
        let moderation = RoomEntry(
            nick: "eve", id: "m2", stamp: "10:01:00", body: "A moderator removed a message",
            payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'><moderated xmlns='urn:xmpp:message-moderate:1' by='\(roomJID)/eve'/></retract>"
        )
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "keep", at: "10:00:00"), moderation], complete: true, answered: &answered
        )

        _ = try await fetch.value
        let stored = try await harness.storedMessages()
        #expect(stored.map(\.body) == ["keep"])
        #expect(stored.first?.isRetracted == false)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
