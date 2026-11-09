import DuckoTestSupport
import Foundation
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// A groupchat message as the room's archive returns it, known to the archive by the stanza-id it stamped, else as
/// `arch-<id>`. Without `nick` it comes from the room itself, and carries no occupant id.
struct RoomEntry {
    var nick: String? = "bob"
    var occupantID = "occupant-bob"
    let id: String
    var serverID: String?
    let stamp: String
    var body: String?
    var payload = ""

    var archiveID: String {
        serverID ?? "arch-\(id)"
    }

    func xml(queryID: String) -> String {
        let from = nick.map { "\(roomJID)/\($0)" } ?? roomJID.description
        let stanzaID = serverID.map { "<stanza-id xmlns='urn:xmpp:sid:0' id='\($0)' by='\(roomJID)'/>" } ?? ""
        let occupant = nick == nil ? "" : "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='\(occupantID)'/>"
        return "<message from='\(roomJID)'>"
            + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'>"
            + "<delay xmlns='urn:xmpp:delay' stamp='2026-02-28T\(stamp)Z'/>"
            + "<message from='\(from)' type='groupchat' id='\(id)'>"
            + (body.map { "<body>\($0)</body>" } ?? "")
            + payload + occupant + stanzaID
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

/// A chat service connected to an archive, with the room `roomJID` stored, in which the user is `alice`, known by the
/// occupant id `ownOccupantID` unless it is nil. The account and the room archive and stamp trusted stanza-ids, and the
/// room advertises occupant ids.
@MainActor
struct ArchiveHarness {
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let room: Conversation
    let accountID: UUID

    static func connect(ownOccupantID: String? = "occupant-alice") async throws -> ArchiveHarness {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let transport = MockTransport()
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MAMModule()]))
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        chatService.featureSource = FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.occupantID])
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let accountID = try await connectTask.value
        let room = Conversation(
            id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
            isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "alice", roomOccupantID: ownOccupantID, createdAt: Date()
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

    /// Starts catch-up and answers the account archive's query with an empty last page, so it reads the room's next.
    func startCatchUp(answered: inout Set<String>) async throws -> Task<Void, Never> {
        let catchUp = Task { @MainActor in await chatService.syncRecentHistory(accountID: accountID) }
        let query = try await nextArchiveQuery(on: transport, answered: &answered)
        await transport.simulateReceive("<iq type='result' id='\(query.iqID)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>")
        return catchUp
    }

    /// Answers the next archive query with `entries` as one page, whose `fin` names its first entry.
    func answerNextQuery(with entries: [RoomEntry], complete: Bool, answered: inout Set<String>) async throws {
        let query = try await nextArchiveQuery(on: transport, answered: &answered)
        for entry in entries {
            await transport.simulateReceive(entry.xml(queryID: query.queryID))
        }
        let first = entries.first.map { "<first>\($0.archiveID)</first>" } ?? ""
        await transport.simulateReceive(
            "<iq type='result' id='\(query.iqID)' from='\(roomJID)'>"
                + "<fin xmlns='urn:xmpp:mam:2'\(complete ? " complete='true'" : "")>"
                + "<set xmlns='http://jabber.org/protocol/rsm'>\(first)</set></fin></iq>"
        )
    }

    func storedMessages() async throws -> [ChatMessage] {
        try await transcripts.fetchMessages(for: room.id, before: nil, limit: 50)
    }

    /// Stores a message `bob` sent, known by the occupant id `occupantID` unless it is nil.
    func addMessage(_ id: String, serverID: String?, body: String, occupantID: String? = "occupant-bob", isEncrypted: Bool = false) async {
        await transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: room.id, stanzaID: id, serverID: serverID, fromJID: "bob", roomSender: occupantID.map { RoomSenderIdentity(occupantID: $0) },
            body: body,
            timestamp: Date(timeIntervalSince1970: 1_772_272_800), isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat",
            isEncrypted: isEncrypted
        ))
    }
}
