import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let accountJID = BareJID(localPart: "alice", domainPart: "example.com")!
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let strangerJID = BareJID(localPart: "stranger", domainPart: "example.org")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let otherRoomJID = BareJID(localPart: "other", domainPart: "conference.example.com")!

/// One result of the account's own archive, which knows it as `archiveID`.
private struct ArchiveEntry {
    let archiveID: String
    /// The archived `<message>`.
    let message: String
    var stamp = "2026-03-01T10:00:00Z"

    func result(queryID: String) -> String {
        "<message><result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>"
            + "<forwarded xmlns='urn:xmpp:forward:0'><delay xmlns='urn:xmpp:delay' stamp='\(stamp)'/>\(message)</forwarded>"
            + "</result></message>"
    }
}

private func message(from: String, to: String, type: String = "chat", id: String, _ content: String) -> String {
    "<message from='\(from)' to='\(to)' type='\(type)' id='\(id)'>\(content)</message>"
}

private func incoming(from: String, id: String, _ content: String) -> String {
    message(from: from, to: "\(accountJID)/ducko", id: id, content)
}

private let omemoPayload = "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/><payload>AAAA</payload></encrypted>"

private func chat(with jid: BareJID, accountID: UUID, nickname: String? = nil, type: Conversation.ConversationType = .chat) -> Conversation {
    Conversation(
        id: UUID(), accountID: accountID, jid: jid, type: type, isPinned: false, isMuted: false, unreadCount: 0,
        occupantNickname: nickname, createdAt: Date()
    )
}

private func storedMessage(in conversation: Conversation, at stamp: String) throws -> ChatMessage {
    try ChatMessage(
        id: UUID(), conversationID: conversation.id, stanzaID: UUID().uuidString, fromJID: conversation.jid.description,
        body: "stored", timestamp: Date.ISO8601FormatStyle().parse(stamp), isOutgoing: false, isDelivered: false, isEdited: false,
        type: "chat"
    )
}

/// Stores a message sent at `stamp` in `conversation`, which takes it as its last message, as a received one does.
private func seedMessage(
    at stamp: String, in conversation: Conversation, store: MockPersistenceStore, transcripts: MockTranscriptStore
) async throws {
    let message = try storedMessage(in: conversation, at: stamp)
    await transcripts.addMessage(message)
    try await store.updateConversation(conversation.id) { $0.recordLastMessage(message, winsTies: true) }
}

/// A connected account whose chat service notes where catch-up starts on connect, as `AppEnvironment` wires it.
@MainActor
private struct CatchUpHarness {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let accountID: UUID
    let connection: Task<Void, any Error>
    /// Connects once `seed` has stored what the account holds before it connects.
    static func connect(
        seed: (_ store: MockPersistenceStore, _ transcripts: MockTranscriptStore, _ accountID: UUID) async throws -> Void = { _, _, _ in }
    ) async throws -> CatchUpHarness {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let account = Account(id: UUID(), jid: accountJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        try await seed(store, transcripts, account.id)
        let transport = MockTransport()
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MAMModule()]))
        try await accountService.loadAccounts()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        accountService.onSessionStarting = { [chatService] in await chatService.captureCatchUpStart(accountID: $0) }
        let (_, connection) = try await driveMockConnect(accountService, accountID: account.id, transport: transport)
        return CatchUpHarness(
            store: store, transcripts: transcripts, transport: transport, accountService: accountService, chatService: chatService,
            accountID: account.id, connection: connection
        )
    }

    /// Runs catch-up and answers the account archive's queries with `pages` in turn. The last page's `fin` reports the
    /// archive `complete`. Then the query of each of `rooms` rooms gets an empty last page, or an error for a room in
    /// `failingRooms`. Returns every archive query the service sent.
    func catchUp(pages: [[ArchiveEntry]], complete: Bool = true, rooms: Int = 0, failingRooms: Set<BareJID> = []) async throws -> [String] {
        let tasks = await startCatchUp()
        var answered: Set<String> = []
        for (index, page) in pages.enumerated() {
            let query = try await nextArchiveQuery(on: transport, answered: &answered)
            for entry in page {
                await transport.simulateReceive(entry.result(queryID: query.queryID))
            }
            let isComplete = index == pages.count - 1 && complete
            let last = page.last.map { "<last>\($0.archiveID)</last>" } ?? ""
            await transport.simulateReceive(
                "<iq type='result' id='\(query.iqID)'><fin xmlns='urn:xmpp:mam:2'\(isComplete ? " complete='true'" : "")>"
                    + "<set xmlns='http://jabber.org/protocol/rsm'>\(last)</set></fin></iq>"
            )
        }
        for _ in 0 ..< rooms {
            let query = try await nextArchiveQuery(on: transport, answered: &answered)
            let room = try #require([roomJID, otherRoomJID].first { query.iq.contains("to=\"\($0)\"") })
            await transport.simulateReceive(
                failingRooms.contains(room)
                    ? "<iq type='error' id='\(query.iqID)' from='\(room)'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
                    : "<iq type='result' id='\(query.iqID)' from='\(room)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>"
            )
        }
        try await Self.drain(tasks)
        return await sentArchiveQueries()
    }

    /// Runs catch-up, answering the account archive's query with an error.
    func failCatchUp() async throws {
        let tasks = await startCatchUp()
        var answered: Set<String> = []
        let query = try await nextArchiveQuery(on: transport, answered: &answered)
        await transport.simulateReceive(
            "<iq type='error' id='\(query.iqID)'><error type='cancel'><service-unavailable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
        )
        try await Self.drain(tasks)
    }

    /// Runs catch-up with nothing in the account archive, and ends the session while the first room's archive is read.
    /// The account is disconnected, but the client's teardown is held at the unavailable presence, so the room's answer
    /// still reaches it. Returns every archive query the service sent.
    func catchUpEndingSessionInFirstRoom() async throws -> [String] {
        let tasks = await startCatchUp()
        var answered: Set<String> = []
        let accountQuery = try await nextArchiveQuery(on: transport, answered: &answered)
        await transport.simulateReceive("<iq type='result' id='\(accountQuery.iqID)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>")
        let roomQuery = try await nextArchiveQuery(on: transport, answered: &answered)
        let room = try #require([roomJID, otherRoomJID].first { roomQuery.iq.contains("to=\"\($0)\"") })
        await transport.blockSends { $0.hasPrefix("<presence") && $0.contains("unavailable") }
        let disconnection = Task { await accountService.disconnect(accountID: accountID) }
        let held = try await boundedOutcome { await transport.waitForBlockedSend() }
        try #require(held != nil)

        await transport.simulateReceive(
            "<iq type='result' id='\(roomQuery.iqID)' from='\(room)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>"
        )
        let drained = try await boundedOutcome {
            for task in tasks {
                await task.value
            }
        }
        let queries = await sentArchiveQueries()
        await transport.releaseBlockedSends()
        await disconnection.value
        #expect(drained != nil)
        return queries
    }

    func disconnect() async {
        connection.cancel()
        await accountService.disconnect(accountID: accountID)
    }

    /// Starts catch-up, as the roster's first delivery on a session does, and returns its tasks.
    private func startCatchUp() async -> [Task<Void, Never>] {
        await transport.clearSentBytes()
        await chatService.handleEvent(
            .rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: accountID
        )
        return chatService.takePendingTasks()
    }

    /// Waits for `tasks` to finish, no longer than `boundedOutcome` does.
    private static func drain(_ tasks: [Task<Void, Never>]) async throws {
        let drained = try await boundedOutcome {
            for task in tasks {
                await task.value
            }
        }
        try #require(drained != nil)
    }

    private func sentArchiveQueries() async -> [String] {
        await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("urn:xmpp:mam:2") }
    }
}

/// Where an entry of the account's archive should land: a chat with `jid`, a room's private chat with `nickname`.
struct CatchUpRoute: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let message: String
    let jid: BareJID?
    var nickname: String?
    var isOutgoing = false
    var isUndecryptable = false
}

private let routes = [
    CatchUpRoute(
        testDescription: "A message from someone without a chat creates one",
        message: incoming(from: "\(strangerJID)/phone", id: "m1", "<body>hi</body>"), jid: strangerJID
    ),
    CatchUpRoute(
        testDescription: "A message the account sent goes to the recipient's chat",
        message: message(from: "\(accountJID)/laptop", to: "\(strangerJID)/phone", id: "m2", "<body>hi</body>"),
        jid: strangerJID, isOutgoing: true
    ),
    CatchUpRoute(
        testDescription: "A room occupant's message goes to the private chat with them",
        message: incoming(from: "\(roomJID)/bob", id: "m3", "<body>psst</body>"), jid: roomJID, nickname: "bob"
    ),
    CatchUpRoute(
        testDescription: "An OMEMO message without a body creates a chat with its undecryptable row",
        message: incoming(from: "\(strangerJID)/phone", id: "m4", omemoPayload), jid: strangerJID, isUndecryptable: true
    ),
    CatchUpRoute(
        testDescription: "A message encrypted with another method creates a chat with an undecryptable row",
        message: incoming(from: "\(strangerJID)/phone", id: "m5", "<encryption xmlns='urn:xmpp:eme:0' namespace='urn:xmpp:openpgp:0'/>"),
        jid: strangerJID, isUndecryptable: true
    ),
    CatchUpRoute(
        testDescription: "An OMEMO message without a payload creates nothing",
        message: incoming(from: "\(strangerJID)/phone", id: "m6", "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted>"),
        jid: nil
    ),
    CatchUpRoute(
        testDescription: "A chat state without a body creates nothing",
        message: incoming(from: "\(strangerJID)/phone", id: "m7", "<active xmlns='http://jabber.org/protocol/chatstates'/>"), jid: nil
    ),
    CatchUpRoute(
        testDescription: "A room message creates nothing",
        message: message(from: "\(roomJID)/bob", to: "\(accountJID)/ducko", type: "groupchat", id: "m8", "<body>all</body>"), jid: nil
    ),
    CatchUpRoute(
        testDescription: "A message from the room's own address creates nothing",
        message: incoming(from: roomJID.description, id: "m9", "<body>notice</body>"), jid: nil
    ),
    CatchUpRoute(
        testDescription: "A message from the account's server creates nothing",
        message: incoming(from: "example.com", id: "m10", "<body>maintenance</body>"), jid: nil
    ),
    CatchUpRoute(
        testDescription: "A room's invite creates nothing",
        message: incoming(
            from: otherRoomJID.description, id: "m11",
            "<body>join us</body><x xmlns='http://jabber.org/protocol/muc#user'><invite from='\(strangerJID)'/></x>"
        ),
        jid: nil
    ),
    CatchUpRoute(
        testDescription: "A direct invite creates nothing",
        message: incoming(from: "\(strangerJID)/phone", id: "m12", "<body>join us</body><x xmlns='jabber:x:conference' jid='\(otherRoomJID)'/>"),
        jid: nil
    ),
    CatchUpRoute(
        testDescription: "A direct invite from a room occupant creates nothing",
        message: incoming(from: "\(roomJID)/bob", id: "m13", "<body>join us</body><x xmlns='jabber:x:conference' jid='\(otherRoomJID)'/>"),
        jid: nil
    ),
    CatchUpRoute(
        testDescription: "A private message from a room the user has no chat with creates nothing",
        message: incoming(from: "\(otherRoomJID)/carol", id: "m14", "<body>psst</body><x xmlns='http://jabber.org/protocol/muc#user'/>"),
        jid: nil
    ),
    CatchUpRoute(
        testDescription: "A correction from someone without a chat creates nothing",
        message: incoming(from: "\(strangerJID)/phone", id: "m15", "<body>fixed</body><replace xmlns='urn:xmpp:message-correct:0' id='m1'/>"),
        jid: nil
    )
]

enum ChatServiceCatchUpTests {
    @MainActor
    struct Paging {
        @Test
        func `Catch-up pages forward from the start until the archive is complete`() async throws {
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                try await store.upsertConversation(conversation)
                try await seedMessage(at: "2026-03-01T09:00:00Z", in: conversation, store: store, transcripts: transcripts)
            }
            let first = ArchiveEntry(archiveID: "arch-1", message: incoming(from: "\(contactJID)/phone", id: "c1", "<body>one</body>"))
            let second = ArchiveEntry(archiveID: "arch-2", message: incoming(from: "\(contactJID)/phone", id: "c2", "<body>two</body>"))

            let queries = try await harness.catchUp(pages: [[first], [second]])

            #expect(queries.count == 2)
            #expect(queries.allSatisfy { $0.contains("2026-03-01T09:00:00Z") })
            #expect(queries.last?.contains("<after>arch-1</after>") == true)
            #expect(await harness.transcripts.messages.map(\.body) == ["stored", "one", "two"])
            await harness.disconnect()
        }

        @Test
        func `With nothing stored, catch-up reads only the newest page`() async throws {
            let harness = try await CatchUpHarness.connect()
            let entry = ArchiveEntry(archiveID: "arch-9", message: incoming(from: "\(contactJID)/phone", id: "c9", "<body>newest</body>"))

            let queries = try await harness.catchUp(pages: [[entry]], complete: false)

            #expect(queries.count == 1)
            #expect(queries.first?.contains("<before/>") == true)
            #expect(await harness.transcripts.messages.map(\.body) == ["newest"])
            await harness.disconnect()
        }

        @Test
        func `A message stored after connecting does not move the start past what only the archive has`() async throws {
            var offlineChat: Conversation?
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                try await store.upsertConversation(conversation)
                try await seedMessage(at: "2026-03-01T09:00:00Z", in: conversation, store: store, transcripts: transcripts)
                offlineChat = conversation
            }
            // Held offline and delivered on connect, before catch-up runs.
            try await seedMessage(at: "2026-03-02T08:00:00Z", in: #require(offlineChat), store: harness.store, transcripts: harness.transcripts)
            let archived = ArchiveEntry(archiveID: "arch-1", message: incoming(from: "\(strangerJID)/phone", id: "s1", "<body>missed</body>"))

            let queries = try await harness.catchUp(pages: [[archived]])

            #expect(queries.first?.contains("2026-03-01T09:00:00Z") == true)
            let stranger = try await harness.store.fetchConversations(for: harness.accountID).first { $0.jid == strangerJID }
            let messages = await harness.transcripts.messages
            #expect(messages.contains { $0.conversationID == stranger?.id && $0.body == "missed" })
            await harness.disconnect()
        }

        @Test
        func `A room's archive is read from the room's own start`() async throws {
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                let room = chat(with: roomJID, accountID: accountID, type: .groupchat)
                try await store.upsertConversation(conversation)
                try await store.upsertConversation(room)
                try await seedMessage(at: "2026-03-01T09:00:00Z", in: conversation, store: store, transcripts: transcripts)
                try await seedMessage(at: "2026-03-01T11:00:00Z", in: room, store: store, transcripts: transcripts)
            }

            let queries = try await harness.catchUp(pages: [[]], rooms: 1)

            #expect(queries.count == 2)
            #expect(queries.first?.contains("2026-03-01T09:00:00Z") == true)
            #expect(queries.last?.contains("2026-03-01T11:00:00Z") == true)
            await harness.disconnect()
        }

        @Test
        func `An archive that names the same last entry again is read no further`() async throws {
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                try await store.upsertConversation(conversation)
                try await seedMessage(at: "2026-03-01T09:00:00Z", in: conversation, store: store, transcripts: transcripts)
            }
            let entry = ArchiveEntry(archiveID: "arch-1", message: incoming(from: "\(contactJID)/phone", id: "c1", "<body>one</body>"))

            let queries = try await harness.catchUp(pages: [[entry], [entry]], complete: false)

            #expect(queries.count == 2)
            await harness.disconnect()
        }
    }

    @MainActor
    struct Start {
        /// Connects with a chat whose last message came at 09:00, and returns the harness with that chat.
        private func connect() async throws -> (harness: CatchUpHarness, chat: Conversation) {
            var seeded: Conversation?
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                try await store.upsertConversation(conversation)
                try await seedMessage(at: "2026-03-01T09:00:00Z", in: conversation, store: store, transcripts: transcripts)
                seeded = conversation
            }
            return try (harness, #require(seeded))
        }

        /// A message received after a catch-up, then a reconnect, which notes the start again.
        private func receiveAndReconnect(_ harness: CatchUpHarness, in conversation: Conversation) async throws {
            try await seedMessage(at: "2026-03-02T08:00:00Z", in: conversation, store: harness.store, transcripts: harness.transcripts)
            await harness.chatService.captureCatchUpStart(accountID: harness.accountID)
        }

        @Test
        func `A catch-up that fails leaves its start to the next one, ahead of a later message's`() async throws {
            let (harness, conversation) = try await connect()
            try await harness.failCatchUp()
            try await receiveAndReconnect(harness, in: conversation)

            let queries = try await harness.catchUp(pages: [[]])

            #expect(queries.last?.contains("2026-03-01T09:00:00Z") == true)
            await harness.disconnect()
        }

        @Test
        func `A completed catch-up lets the next one start after a later message`() async throws {
            let (harness, conversation) = try await connect()
            _ = try await harness.catchUp(pages: [[]])
            try await receiveAndReconnect(harness, in: conversation)

            let queries = try await harness.catchUp(pages: [[]])

            #expect(queries.last?.contains("2026-03-02T08:00:00Z") == true)
            await harness.disconnect()
        }
    }

    /// Each room's archive has a start of its own, and is read on its own.
    @MainActor
    struct Rooms {
        private struct Seeded {
            let harness: CatchUpHarness
            let chat: Conversation
            let rooms: [Conversation]
        }

        /// Connects with a chat whose last message came at 09:00, and the rooms `roomJID` and `otherRoomJID`, whose
        /// last ones came at 11:00 and 12:00.
        private func connect() async throws -> Seeded {
            var seeded: (chat: Conversation, rooms: [Conversation])?
            let harness = try await CatchUpHarness.connect { store, transcripts, accountID in
                let conversation = chat(with: contactJID, accountID: accountID)
                let rooms = [roomJID, otherRoomJID].map { chat(with: $0, accountID: accountID, type: .groupchat) }
                for (conversation, stamp) in zip([conversation] + rooms, ["2026-03-01T09:00:00Z", "2026-03-01T11:00:00Z", "2026-03-01T12:00:00Z"]) {
                    try await store.upsertConversation(conversation)
                    try await seedMessage(at: stamp, in: conversation, store: store, transcripts: transcripts)
                }
                seeded = (conversation, rooms)
            }
            let (chat, rooms) = try #require(seeded)
            return Seeded(harness: harness, chat: chat, rooms: rooms)
        }

        /// A message received in the chat and in each room after a catch-up, then a reconnect, which notes the start
        /// again.
        private func receiveAndReconnect(_ seeded: Seeded) async throws {
            for conversation in [seeded.chat] + seeded.rooms {
                try await seedMessage(at: "2026-03-02T08:00:00Z", in: conversation, store: seeded.harness.store, transcripts: seeded.harness.transcripts)
            }
            await seeded.harness.chatService.captureCatchUpStart(accountID: seeded.harness.accountID)
        }

        @Test
        func `A catch-up that fails leaves each room its start, ahead of a later message's`() async throws {
            let seeded = try await connect()
            try await seeded.harness.failCatchUp()
            try await receiveAndReconnect(seeded)

            let queries = try await seeded.harness.catchUp(pages: [[]], rooms: 2)

            #expect(queries.map { $0.contains("2026-03-01T") } == [true, true, true])
            await seeded.harness.disconnect()
        }

        @Test
        func `A room whose archive cannot be read does not stop the rooms after it`() async throws {
            let seeded = try await connect()

            let queries = try await seeded.harness.catchUp(pages: [[]], rooms: 2, failingRooms: [roomJID])

            #expect(queries.count == 3)
            #expect(queries.last?.contains("to=\"\(otherRoomJID)\"") == true)
            await seeded.harness.disconnect()
        }

        @Test
        func `Catch-up reads no room's archive once its session has ended`() async throws {
            let seeded = try await connect()

            let queries = try await seeded.harness.catchUpEndingSessionInFirstRoom()

            #expect(queries.count == 2)
            await seeded.harness.disconnect()
        }

        @Test
        func `A room whose archive cannot be read keeps only its own start for the next catch-up`() async throws {
            let seeded = try await connect()
            _ = try await seeded.harness.catchUp(pages: [[]], rooms: 2, failingRooms: [roomJID])
            try await receiveAndReconnect(seeded)

            let queries = try await seeded.harness.catchUp(pages: [[]], rooms: 2)

            #expect(queries.count == 3)
            #expect(queries.map { $0.contains("2026-03-01T11:00:00Z") } == [false, true, false])
            #expect(queries.map { $0.contains("2026-03-02T08:00:00Z") } == [true, false, true])
            await seeded.harness.disconnect()
        }
    }

    @MainActor
    struct Routing {
        @Test(arguments: routes)
        func `An entry of the account's archive lands in the chat it belongs to`(route: CatchUpRoute) async throws {
            var room: Conversation?
            let harness = try await CatchUpHarness.connect { store, _, accountID in
                let conversation = chat(with: roomJID, accountID: accountID, type: .groupchat)
                try await store.upsertConversation(conversation)
                room = conversation
            }

            _ = try await harness.catchUp(pages: [[ArchiveEntry(archiveID: "arch-1", message: route.message)]], rooms: 1)

            let created = try await harness.store.fetchConversations(for: harness.accountID).filter { $0.id != room?.id }
            let messages = await harness.transcripts.messages
            if let jid = route.jid {
                let conversation = try #require(created.first)
                #expect(created.count == 1)
                #expect(conversation.jid == jid)
                #expect(conversation.occupantNickname == route.nickname)
                let message = try #require(messages.first)
                #expect(messages.count == 1)
                #expect(message.conversationID == conversation.id)
                #expect(message.isOutgoing == route.isOutgoing)
                #expect(message.isUndecryptable == route.isUndecryptable)
            } else {
                #expect(created.isEmpty)
                #expect(messages.isEmpty)
            }
            await harness.disconnect()
        }

        @Test
        func `Once its room is gone, a room occupant's message still goes to a private chat with them`() async throws {
            let harness = try await CatchUpHarness.connect { store, _, accountID in
                try await store.upsertConversation(chat(with: roomJID, accountID: accountID, nickname: "bob"))
            }
            let entry = ArchiveEntry(archiveID: "arch-1", message: incoming(from: "\(roomJID)/carol", id: "p2", "<body>psst</body>"))

            _ = try await harness.catchUp(pages: [[entry]])

            let conversations = try await harness.store.fetchConversations(for: harness.accountID)
            #expect(conversations.map(\.occupantNickname).sorted { ($0 ?? "") < ($1 ?? "") } == ["bob", "carol"])
            await harness.disconnect()
        }

        @Test
        func `A room private message received live and its archived copy are one row`() async throws {
            let harness = try await CatchUpHarness.connect { store, _, accountID in
                try await store.upsertConversation(chat(with: roomJID, accountID: accountID, type: .groupchat))
            }
            var live = XMPPMessage(type: .chat, to: .bare(accountJID), id: "p1")
            live.from = try .full(#require(FullJID(bareJID: roomJID, resourcePart: "bob")))
            live.body = "psst"
            live.element.addChild(DuckoXMPP.XMLElement(
                name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "S1", "by": accountJID.description]
            ))
            await harness.chatService.handleEvent(.mucPrivateMessageReceived(live), accountID: harness.accountID)
            let archived = ArchiveEntry(archiveID: "S1", message: incoming(
                from: "\(roomJID)/bob", id: "p1", "<body>psst</body><stanza-id xmlns='urn:xmpp:sid:0' id='S1' by='\(accountJID)'/>"
            ))

            _ = try await harness.catchUp(pages: [[archived]], rooms: 1)

            #expect(await harness.transcripts.messages.map(\.body) == ["psst"])
            await harness.disconnect()
        }
    }
}
