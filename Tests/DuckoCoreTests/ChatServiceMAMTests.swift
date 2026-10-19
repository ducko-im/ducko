import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let contactJID = BareJID(localPart: "contact", domainPart: "example.com")!
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

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

// MARK: - MAM Ingest Helpers

/// Connected ChatService bundle pre-seeded with one conversation, used to drive `fetchServerHistory` against simulated
/// MAM archives. The conversation is the room (nickname `alice`), or with `type: .chat` a chat with `contactJID`.
@MainActor
private struct MAMHarness {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let conversation: Conversation
    let accountID: UUID
}

@MainActor
private func makeMAMHarness(
    filters: [any MessageFilter] = [], transcriptStore: (any TranscriptStore)? = nil, type: Conversation.ConversationType = .groupchat,
    modules: [any XMPPModule] = [MAMModule()]
) async throws -> MAMHarness {
    let store = makeStore()
    let transcripts = makeTranscripts()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: modules)
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let pipeline = MessageFilterPipeline()
    for filter in filters {
        await pipeline.register(filter)
    }
    let chatService = ChatService(store: store, transcripts: transcriptStore ?? transcripts, filterPipeline: pipeline)
    chatService.setAccountService(accountService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value

    let conversation = Conversation(
        id: UUID(), accountID: accountID, jid: type == .groupchat ? roomJID : contactJID, type: type,
        isPinned: false, isMuted: false, unreadCount: 0,
        roomNickname: type == .groupchat ? "alice" : nil, createdAt: Date()
    )
    try await store.upsertConversation(conversation)

    return MAMHarness(
        store: store, transcripts: transcripts, transport: transport,
        accountService: accountService, chatService: chatService,
        conversation: conversation, accountID: accountID
    )
}

/// Drives `fetchServerHistory` for the harness's conversation, feeds the archive stanzas built from the captured
/// queryid, then a complete `fin`, and returns the newly imported messages.
@MainActor
private func ingestArchives(
    harness: MAMHarness,
    finCount: Int,
    archives: (_ queryID: String) -> [String]
) async throws -> [ChatMessage] {
    let fetchTask = Task { @MainActor in
        try await harness.chatService.fetchServerHistory(
            jid: harness.conversation.jid, accountID: harness.accountID, before: nil, limit: 50
        )
    }
    // The connect handshake sends 4 stanzas; the MAM query IQ is the 5th.
    await harness.transport.waitForSent(count: 5)
    let sent = await harness.transport.sentBytes
    let mamIQ = try #require(
        sent.map { String(decoding: $0, as: UTF8.self) }.first { $0.contains("urn:xmpp:mam:2") }
    )
    let iqID = try #require(extractIQID(from: mamIQ))
    let queryID = try #require(extractQueryID(from: mamIQ))

    for archive in archives(queryID) {
        await harness.transport.simulateReceive(archive)
    }
    // The account's own archive may leave its address out.
    let from = harness.conversation.type == .groupchat ? " from='\(roomJID.description)'" : ""
    await harness.transport.simulateReceive(
        "<iq type='result' id='\(iqID)'\(from)>"
            + "<fin xmlns='urn:xmpp:mam:2' complete='true'>"
            + "<set xmlns='http://jabber.org/protocol/rsm'><count>\(finCount)</count></set></fin></iq>"
    )

    let (messages, _) = try await fetchTask.value
    return messages
}

/// Describes a groupchat message to wrap in a MAM `<result>`, stamped with a trusted `<stanza-id by=room>`.
private struct GroupArchiveSpec {
    let fromNick: String
    let serverID: String
    let stanzaID: String
    let body: String
    var encrypted = false
    var omitsBody = false
    var metadataXML = ""
}

private func groupArchive(queryID: String, archiveID: String, _ spec: GroupArchiveSpec) -> String {
    let encryptedElement = spec.encrypted
        ? "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted>"
        : ""
    return "<message from='\(roomJID.description)'>"
        + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>"
        + "<forwarded xmlns='urn:xmpp:forward:0'>"
        + "<delay xmlns='urn:xmpp:delay' stamp='2026-02-28T10:00:00Z'/>"
        + "<message from='\(roomJID.description)/\(spec.fromNick)' type='groupchat' id='\(spec.stanzaID)'>"
        + (spec.omitsBody ? "" : "<body>\(spec.body)</body>")
        + encryptedElement
        + spec.metadataXML
        + "<stanza-id xmlns='urn:xmpp:sid:0' id='\(spec.serverID)' by='\(roomJID.description)'/>"
        + "</message></forwarded></result></message>"
}

/// Describes an encrypted 1:1 message to wrap in a result of the account's own archive, which knows it as `archiveID`.
private struct ChatArchiveSpec {
    let from: BareJID
    let stanzaID: String
    /// The archive's stamp inside the archived message, left out when nil.
    var serverID: String?
    var stamp = "2026-02-28T10:00:00Z"
}

private func chatArchive(queryID: String, archiveID: String, _ spec: ChatArchiveSpec) -> String {
    let stanzaIDElement = spec.serverID.map { "<stanza-id xmlns='urn:xmpp:sid:0' id='\($0)' by='\(testJIDString)'/>" } ?? ""
    return "<message>"
        + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(archiveID)'>"
        + "<forwarded xmlns='urn:xmpp:forward:0'>"
        + "<delay xmlns='urn:xmpp:delay' stamp='\(spec.stamp)'/>"
        + "<message from='\(spec.from)/res' type='chat' id='\(spec.stanzaID)'>"
        + "<body>\(omemoFallbackBody)</body>"
        + "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/></encrypted>"
        + stanzaIDElement
        + "</message></forwarded></result></message>"
}

/// The next archive query the service sends that `answered` does not hold yet.
@MainActor
private func nextArchiveQuery(_ harness: MAMHarness, answered: inout Set<String>) async throws -> ArchiveQuery {
    let seen = answered
    let waiting = Task { [transport = harness.transport] in
        await transport.waitForSent(matching: { $0.contains("urn:xmpp:mam:2") && !seen.contains(extractIQID(from: $0) ?? "") })
    }
    try #require(try await boundedOutcome { _ = await waiting.value } != nil)
    let iq = try #require(await waiting.value)
    let iqID = try #require(extractIQID(from: iq))
    answered.insert(iqID)
    return try ArchiveQuery(iq: iq, iqID: iqID, queryID: #require(extractQueryID(from: iq)))
}

private struct ArchiveQuery {
    let iq: String
    let iqID: String
    let queryID: String
}

/// The room archive's closing answer to a query. An incomplete one names the page's first entry.
private func roomFin(iqID: String, complete: Bool, first: String? = nil) -> String {
    "<iq type='result' id='\(iqID)' from='\(roomJID.description)'>"
        + "<fin xmlns='urn:xmpp:mam:2'\(complete ? " complete='true'" : "")>"
        + "<set xmlns='http://jabber.org/protocol/rsm'>\(first.map { "<first>\($0)</first>" } ?? "")</set></fin></iq>"
}

// MARK: - Tests

enum ChatServiceMAMTests {
    struct RosterLoadedHandler {
        @Test
        @MainActor
        func `rosterLoaded event is handled without error`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Fire initial roster response — syncRecentHistory exits early (no client), no crash
            await service.handleEvent(.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: testAccountID)

            // Give the fire-and-forget Task time to complete
            try await Task.sleep(for: .milliseconds(50))

            // No conversations created (sync had no client, did nothing)
            let conversations = try await store.fetchConversations(for: testAccountID)
            #expect(conversations.isEmpty)
        }
    }

    struct FetchServerHistory {
        @Test
        @MainActor
        func `Throws notConnected when no client available`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            await #expect(throws: ChatService.ChatServiceError.self) {
                _ = try await service.fetchServerHistory(
                    jid: contactJID, accountID: testAccountID, before: nil, limit: 50
                )
            }
        }

        @Test
        @MainActor
        func `String overload throws for invalid JID`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            await #expect(throws: ChatService.ChatServiceError.self) {
                _ = try await service.fetchServerHistory(
                    jidString: "", accountID: testAccountID, before: nil, limit: 50
                )
            }
        }

        @Test
        @MainActor
        func `Throws notConnected for groupchat conversation without client`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Pre-create a groupchat conversation so the code path exercises MUC logic
            let conversation = Conversation(
                id: UUID(),
                accountID: testAccountID,
                jid: roomJID,
                type: .groupchat,
                isPinned: false,
                isMuted: false,
                unreadCount: 0,
                roomNickname: "mynick",
                createdAt: Date()
            )
            try await store.upsertConversation(conversation)

            await #expect(throws: ChatService.ChatServiceError.self) {
                _ = try await service.fetchServerHistory(
                    jid: roomJID, accountID: testAccountID, before: nil, limit: 50
                )
            }
        }
    }

    struct ServerPaging {
        @Test
        @MainActor
        func `The first query asks for the last page before the cutoff`() async throws {
            let harness = try await makeMAMHarness()
            let cutoff = try Date.ISO8601FormatStyle().parse("2026-02-28T12:00:00Z")
            let fetchTask = Task { @MainActor in
                try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: cutoff, limit: 50)
            }
            var answered: Set<String> = []

            let query = try await nextArchiveQuery(harness, answered: &answered)

            #expect(query.iq.contains("<before/>"))
            #expect(query.iq.contains("<max>50</max>"))
            #expect(query.iq.contains("2026-02-28T12:00:00Z"))
            await harness.transport.simulateReceive(roomFin(iqID: query.iqID, complete: true))
            let (messages, hasMore) = try await fetchTask.value
            #expect(messages.isEmpty)
            #expect(!hasMore)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `A page that adds nothing is followed by the page before it`() async throws {
            let harness = try await makeMAMHarness()
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S1", serverID: "R1",
                fromJID: "bob", body: "already here", timestamp: Date(),
                isOutgoing: false, isDelivered: true, isEdited: false, type: "groupchat"
            ))
            let fetchTask = Task { @MainActor in
                try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: nil, limit: 50)
            }
            var answered: Set<String> = []

            let first = try await nextArchiveQuery(harness, answered: &answered)
            await harness.transport.simulateReceive(groupArchive(queryID: first.queryID, archiveID: "arch-2", GroupArchiveSpec(
                fromNick: "bob", serverID: "R1", stanzaID: "S1", body: "already here"
            )))
            await harness.transport.simulateReceive(roomFin(iqID: first.iqID, complete: false, first: "arch-2"))

            let second = try await nextArchiveQuery(harness, answered: &answered)
            #expect(second.iq.contains("<before>arch-2</before>"))
            #expect(second.iq.contains("<max>50</max>"))
            await harness.transport.simulateReceive(groupArchive(queryID: second.queryID, archiveID: "arch-1", GroupArchiveSpec(
                fromNick: "bob", serverID: "R0", stanzaID: "S0", body: "older"
            )))
            await harness.transport.simulateReceive(roomFin(iqID: second.iqID, complete: false, first: "arch-1"))

            let (messages, hasMore) = try await fetchTask.value
            #expect(messages.map(\.body) == ["older"])
            #expect(hasMore)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `Ten pages that add nothing end the fetch with more to come`() async throws {
            let harness = try await makeMAMHarness()
            let fetchTask = Task { @MainActor in
                try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: nil, limit: 50)
            }
            var answered: Set<String> = []

            for page in 0 ..< 10 {
                let query = try await nextArchiveQuery(harness, answered: &answered)
                await harness.transport.simulateReceive(roomFin(iqID: query.iqID, complete: false, first: "arch-\(page)"))
            }

            let (messages, hasMore) = try await fetchTask.value
            #expect(messages.isEmpty)
            #expect(hasMore)
            #expect(answered.count == 10)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `An entry that carries no id of its own is stored once, under the archive's id for it`() async throws {
            let harness = try await makeMAMHarness()
            var answered: Set<String> = []
            var fetched: [[ChatMessage]] = []

            for _ in 0 ..< 2 {
                let fetchTask = Task { @MainActor in
                    try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: nil, limit: 50)
                }
                let query = try await nextArchiveQuery(harness, answered: &answered)
                await harness.transport.simulateReceive(
                    "<message from='\(roomJID.description)'>"
                        + "<result xmlns='urn:xmpp:mam:2' queryid='\(query.queryID)' id='arch-7'>"
                        + "<forwarded xmlns='urn:xmpp:forward:0'>"
                        + "<delay xmlns='urn:xmpp:delay' stamp='2026-02-28T10:00:00Z'/>"
                        + "<message from='\(roomJID.description)/bob' type='groupchat'><body>no ids</body></message>"
                        + "</forwarded></result></message>"
                )
                await harness.transport.simulateReceive(roomFin(iqID: query.iqID, complete: true))
                try await fetched.append(fetchTask.value.messages)
            }

            #expect(fetched.map(\.count) == [1, 0])
            #expect(fetched.first?.first?.serverID == "arch-7")
            #expect(await harness.transcripts.messages.count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    /// A room may give the user another nickname than the one asked for, and every copy of the user's own messages,
    /// live or archived, plaintext or encrypted, goes by the nickname the room gave.
    struct ServerAssignedNickname {
        @Test
        @MainActor
        func `Own messages go by the nickname the room gave, live and archived`() async throws {
            let harness = try await makeMAMHarness(modules: [MAMModule(), MUCModule()])
            let client = try #require(harness.accountService.client(for: harness.accountID))
            let muc = try #require(await client.module(ofType: MUCModule.self))
            try await muc.joinRoom(roomJID, nickname: "alice")
            await harness.transport.simulateReceive(
                "<presence from='\(roomJID)/alice_'><x xmlns='http://jabber.org/protocol/muc#user'>"
                    + "<item affiliation='member' role='participant'/><status code='110'/><status code='210'/></x></presence>"
            )
            try await eventually { muc.nickname(in: roomJID) == "alice_" }

            let fetch = Task { @MainActor in
                try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: nil, limit: 50)
            }
            var answered = Set<String>()
            let query = try await nextArchiveQuery(harness, answered: &answered)
            await harness.transport.simulateReceive(groupArchive(queryID: query.queryID, archiveID: "arch-1", GroupArchiveSpec(
                fromNick: "alice_", serverID: "R", stanzaID: "S", body: omemoFallbackBody, encrypted: true
            )))
            await harness.transport.simulateReceive(roomFin(iqID: query.iqID, complete: true))
            _ = try await fetch.value

            // The live copy of the archived message takes its place with the decrypted text.
            let sender = try JID.full(#require(FullJID(bareJID: roomJID, resourcePart: "alice_")))
            var live = XMPPMessage(type: .groupchat, id: "S")
            live.from = sender
            live.element.addChild(DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo))
            live.element.addChild(DuckoXMPP.XMLElement(
                name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "R", "by": roomJID.description]
            ))
            let isOwn = await harness.chatService.isOwnEncryptedMessage(from: sender, in: harness.conversation, accountID: harness.accountID)
            let outcome = await harness.chatService.ingestEncryptedMessage(
                message: live, decryptedBody: "hi", isOutgoing: isOwn, in: harness.conversation, accountID: harness.accountID
            )
            guard case .upgraded = outcome else {
                Issue.record("Expected the archived copy to take the decrypted text, got \(String(describing: outcome))")
                return
            }

            // A plaintext echo under the given nickname is the user's own; the nickname asked for is someone else's now.
            for nickname in ["alice_", "alice"] {
                var plaintext = XMPPMessage(type: .groupchat, id: "plain-\(nickname)")
                plaintext.from = try .full(#require(FullJID(bareJID: roomJID, resourcePart: nickname)))
                plaintext.body = "plain"
                await harness.chatService.handleEvent(.roomMessageReceived(plaintext), accountID: harness.accountID)
            }

            let messages = try await harness.transcripts.fetchMessages(for: harness.conversation.id, before: nil, limit: 10)
            let rows = messages.map { "\($0.body) from \($0.fromJID), outgoing \($0.isOutgoing)" }.sorted()
            #expect(rows == ["hi from alice_, outgoing true", "plain from alice, outgoing false"])
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    /// A join waiting for the room's confirmation leaves the user's nickname as the room last confirmed it, since the
    /// nickname asked for may be another occupant's.
    struct PendingJoin {
        @Test
        @MainActor
        func `Archived messages under the nickname a pending join asked for stay the other occupant's`() async throws {
            let harness = try await makeMAMHarness(modules: [MAMModule(), MUCModule()])
            let client = try #require(harness.accountService.client(for: harness.accountID))
            let muc = try #require(await client.module(ofType: MUCModule.self))
            try await harness.chatService.joinRoom(jid: roomJID, nickname: "bob", accountID: harness.accountID)
            await harness.transport.simulateReceive(
                "<presence from='\(roomJID)/bob'><x xmlns='http://jabber.org/protocol/muc#user'>"
                    + "<item affiliation='member' role='participant'/></x></presence>"
            )
            try await eventually { muc.roomOccupancies[roomJID]?.occupants.contains { $0.nickname == "bob" } == true }

            let fetch = Task { @MainActor in
                try await harness.chatService.fetchServerHistory(jid: roomJID, accountID: harness.accountID, before: nil, limit: 50)
            }
            var answered = Set<String>()
            let query = try await nextArchiveQuery(harness, answered: &answered)
            for (index, nickname) in ["bob", "alice"].enumerated() {
                await harness.transport.simulateReceive(groupArchive(queryID: query.queryID, archiveID: "arch-\(index)", GroupArchiveSpec(
                    fromNick: nickname, serverID: "R\(index)", stanzaID: "S\(index)", body: "from \(nickname)"
                )))
            }
            await harness.transport.simulateReceive(roomFin(iqID: query.iqID, complete: true))
            _ = try await fetch.value

            let messages = try await harness.transcripts.fetchMessages(for: harness.conversation.id, before: nil, limit: 10)
            let rows = messages.map { "\($0.body), outgoing \($0.isOutgoing)" }.sorted()
            #expect(rows == ["from alice, outgoing true", "from bob, outgoing false"])
            let stored = try await harness.store.fetchConversations(for: harness.accountID).first { $0.id == harness.conversation.id }
            #expect(stored?.roomNickname == "alice")
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct OwnMUCMAMDedup {
        @Test
        @MainActor
        func `own plaintext MUC message is not double-imported on MAM replay`() async throws {
            let harness = try await makeMAMHarness()
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "hi room", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S", body: "hi room"
                ))]
            }

            #expect(imported.isEmpty)
            let count = await harness.transcripts.messages.count
            #expect(count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `own encrypted MUC message is not double-imported on MAM replay`() async throws {
            let harness = try await makeMAMHarness()
            // The optimistic row stores plaintext; the archive carries the OMEMO fallback body. The
            // dedup must match on stanzaID + isEncrypted, not body equality.
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "secret plaintext", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat", isEncrypted: true
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S",
                    body: "This message is OMEMO encrypted", encrypted: true
                ))]
            }

            #expect(imported.isEmpty)
            let count = await harness.transcripts.messages.count
            #expect(count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `archived message from a different occupant with a colliding stanzaID is imported`() async throws {
            let harness = try await makeMAMHarness()
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "hi room", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "bob", serverID: "Rbob", stanzaID: "S", body: "hi from bob"
                ))]
            }

            #expect(imported.count == 1)
            #expect(imported.first?.serverID == "Rbob")
            #expect(imported.first?.isOutgoing == false)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `archived own message is imported when the colliding local row already has a serverID`() async throws {
            let harness = try await makeMAMHarness()
            // A reconciled own row (serverID set) must not absorb a genuinely different own message that
            // reused the same `ducko-N` stanzaID — the dedup targets only the un-reconciled (serverID nil) row.
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S2", serverID: "EXISTING",
                fromJID: "alice", body: "earlier", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R2", stanzaID: "S2", body: "later"
                ))]
            }

            #expect(imported.count == 1)
            #expect(imported.first?.serverID == "R2")
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `archived own plaintext message with a colliding stanzaID but different body is imported`() async throws {
            let harness = try await makeMAMHarness()
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "hi room", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S", body: "a different line"
                ))]
            }

            #expect(imported.count == 1)
            #expect(imported.first?.serverID == "R")
            #expect(imported.first?.body == "a different line")
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `a retracted own plaintext MUC message stays suppressed on MAM replay`() async throws {
            let harness = try await makeMAMHarness()
            let optimisticID = UUID()
            await harness.transcripts.addMessage(ChatMessage(
                id: optimisticID, conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "hi room", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
            ))
            // Retracting clears the body, so the replay can't be deduped by body-equality.
            try await harness.transcripts.appendAmendment(
                TranscriptAmendment(action: .retract, targetMessageID: optimisticID, targetStanzaID: "S", timestamp: Date()),
                conversationID: harness.conversation.id
            )

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S", body: "hi room"
                ))]
            }

            // The replay dedups against the retracted row — it must not re-import as a fresh unretracted copy.
            #expect(imported.isEmpty)
            let count = await harness.transcripts.messages.count
            #expect(count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `a retracted own encrypted MUC message stays suppressed on MAM replay`() async throws {
            let harness = try await makeMAMHarness()
            let optimisticID = UUID()
            await harness.transcripts.addMessage(ChatMessage(
                id: optimisticID, conversationID: harness.conversation.id, stanzaID: "S", serverID: nil,
                fromJID: "alice", body: "secret plaintext", timestamp: Date(),
                isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat", isEncrypted: true
            ))
            try await harness.transcripts.appendAmendment(
                TranscriptAmendment(action: .retract, targetMessageID: optimisticID, targetStanzaID: "S", timestamp: Date()),
                conversationID: harness.conversation.id
            )

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S",
                    body: "This message is OMEMO encrypted", encrypted: true
                ))]
            }

            #expect(imported.isEmpty)
            let count = await harness.transcripts.messages.count
            #expect(count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct Filtering {
        @Test
        @MainActor
        func `archived styled message is run through the filter pipeline, populating htmlBody`() async throws {
            let harness = try await makeMAMHarness(filters: [StylingFilter()])

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "bob", serverID: "R", stanzaID: "S", body: "*bold*"
                ))]
            }

            let message = try #require(imported.first)
            #expect(message.body == "*bold*")
            let htmlBody = try #require(message.htmlBody)
            #expect(htmlBody.contains("<strong>bold</strong>"))
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `archived outgoing emoticon body is preserved, not rewritten to emoji`() async throws {
            let harness = try await makeMAMHarness(filters: [EmojiFilter()])

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "alice", serverID: "R", stanzaID: "S", body: "hi :)"
                ))]
            }

            let message = try #require(imported.first)
            #expect(message.isOutgoing == true)
            // The archive path passes allowBodyMutation: false, so EmojiFilter must not rewrite the stored body
            // away from the server-archived text.
            #expect(message.body == "hi :)")
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `archived URL does not trigger a link-preview fetch`() async throws {
            let fetcher = CountingLinkPreviewFetcher()
            let previewService = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())
            let harness = try await makeMAMHarness(
                filters: [LinkDetectionFilter(), LinkPreviewFilter(previewService: previewService)]
            )

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "bob", serverID: "R", stanzaID: "S", body: "see https://example.com"
                ))]
            }

            #expect(imported.count == 1)
            // makeArchivedMessage passes allowLinkPreviewFetches: false, so LinkPreviewFilter must not fire a
            // network fetch for a URL detected in backfilled history.
            for _ in 0 ..< 5 {
                await Task.yield()
            }
            #expect(await fetcher.invocationCount == 0)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct EncryptedArchive {
        @Test(arguments: [
            (encrypted: true, omitsBody: false),
            (encrypted: false, omitsBody: false),
            (encrypted: true, omitsBody: true)
        ])
        @MainActor
        func `an archived OMEMO message is stored as undecryptable, not as its fallback text`(encrypted: Bool, omitsBody: Bool) async throws {
            let harness = try await makeMAMHarness()

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                    fromNick: "bob", serverID: "R", stanzaID: "S",
                    body: omemoFallbackBody, encrypted: encrypted, omitsBody: omitsBody
                ))]
            }

            let message = try #require(imported.first)
            #expect(message.isEncrypted)
            #expect(message.isUndecryptable)
            #expect(message.body.isEmpty)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    /// An encrypted 1:1 message and its archived copy are one row, which shows the decrypted text whichever came first.
    struct EncryptedChatArchive {
        @MainActor
        private func receiveLive(_ harness: MAMHarness, id: String, serverID: String?, body: String) async {
            await harness.chatService.ingestEncryptedMessage(
                message: makeEncryptedStanza(from: .bare(contactJID), id: id, serverID: serverID), decryptedBody: body,
                isOutgoing: false, in: harness.conversation, accountID: harness.accountID
            )
        }

        @Test(arguments: [String?.some("S1"), nil])
        @MainActor
        func `A message that decrypted live and its archived copy are one readable row`(liveServerID: String?) async throws {
            let harness = try await makeMAMHarness(type: .chat)
            await receiveLive(harness, id: "ducko-3", serverID: liveServerID, body: "hello")

            // Without a trusted stamp inside the archived message, the archive's id for it is its server id.
            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [chatArchive(queryID: queryID, archiveID: "S1", ChatArchiveSpec(from: contactJID, stanzaID: "ducko-3"))]
            }

            #expect(imported.isEmpty)
            let messages = await harness.transcripts.messages
            #expect(messages.map(\.body) == ["hello"])
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `An encrypted message the user sent and its archived copy are one row`() async throws {
            let harness = try await makeMAMHarness(type: .chat)
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "ducko-5", fromJID: contactJID.description,
                body: "secret", timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "chat",
                isEncrypted: true
            ))

            let ownJID = try #require(BareJID.parse(testJIDString))
            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [chatArchive(queryID: queryID, archiveID: "arch-5", ChatArchiveSpec(from: ownJID, stanzaID: "ducko-5", serverID: "S5"))]
            }

            #expect(imported.isEmpty)
            #expect(await harness.transcripts.messages.count == 1)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `An archived message reusing an older one's id under another server id is kept`() async throws {
            let harness = try await makeMAMHarness(type: .chat)
            await harness.transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: harness.conversation.id, stanzaID: "ducko-7", serverID: "S1",
                fromJID: contactJID.description, body: "older", timestamp: Date(), isOutgoing: false, isDelivered: false,
                isEdited: false, type: "chat", isEncrypted: true
            ))

            let imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                [chatArchive(queryID: queryID, archiveID: "arch-7", ChatArchiveSpec(from: contactJID, stanzaID: "ducko-7", serverID: "S2"))]
            }

            #expect(imported.map(\.serverID) == ["S2"])
            #expect(await harness.transcripts.messages.count == 2)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        /// With `liveFirst`, the sync parks before it writes the conversation's last message, so the live copy can
        /// decrypt in between. A stamp with fractions of a second, as some servers send, is kept only to the second in
        /// the transcript.
        @Test(arguments: [true, false], ["2026-02-28T10:00:00Z", "2026-02-28T10:00:00.123Z"])
        @MainActor
        func `The decrypted text is the preview whether the archive sync writes before or after the live copy`(
            liveFirst: Bool, stamp: String
        ) async throws {
            try await withTemporaryDirectory { dir in
                try await assertDecryptedPreview(liveFirst: liveFirst, stamp: stamp, transcripts: FileTranscriptStore(baseDirectory: dir))
            }
        }

        @MainActor
        private func assertDecryptedPreview(liveFirst: Bool, stamp: String, transcripts: FileTranscriptStore) async throws {
            let harness = try await makeMAMHarness(transcriptStore: transcripts, type: .chat)
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            if liveFirst {
                await harness.store.installConversationWriteGate(entered: entered, release: release)
            }

            await harness.chatService.handleEvent(
                .rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: harness.accountID
            )
            let query = try #require(await harness.transport.waitForSent(matching: { $0.contains("urn:xmpp:mam:2") }))
            let tasks = harness.chatService.takePendingTasks()
            let queryID = try #require(extractQueryID(from: query))
            await harness.transport.simulateReceive(chatArchive(
                queryID: queryID, archiveID: "arch-1", ChatArchiveSpec(from: contactJID, stanzaID: "ducko-1", serverID: "S1", stamp: stamp)
            ))
            try await harness.transport.simulateReceive(
                "<iq type='result' id='\(#require(extractIQID(from: query)))'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>"
            )
            if liveFirst {
                // Armed: the archived copy is stored, and the sync waits to write the conversation.
                try #require(try await boundedOutcome { await entered.wait() } != nil)
                await receiveLive(harness, id: "ducko-1", serverID: "S1", body: "hello")
                await release.signal()
            }
            for task in tasks {
                await task.value
            }
            if !liveFirst {
                await receiveLive(harness, id: "ducko-1", serverID: "S1", body: "hello")
            }

            let stored = try #require(
                try await harness.store.fetchConversations(for: harness.accountID).first { $0.id == harness.conversation.id }
            )
            #expect(stored.lastMessagePreview == "hello")
            #expect(try stored.lastMessageDate == Date.ISO8601FormatStyle().parse("2026-02-28T10:00:00Z"))
            let messages = try await transcripts.fetchMessages(for: harness.conversation.id, before: nil, limit: 10)
            #expect(messages.map(\.body) == ["hello"])
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct RecentHistorySync {
        @Test
        @MainActor
        func `the sync does not ask the archive about a room private chat`() async throws {
            let harness = try await makeMAMHarness()
            try await harness.store.updateConversation(harness.conversation.id) {
                $0.type = .chat
                $0.roomNickname = nil
                $0.occupantNickname = "bob"
            }

            await harness.chatService.handleEvent(.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: harness.accountID)
            let tasks = harness.chatService.takePendingTasks()
            try #require(!tasks.isEmpty)
            let drained = try await boundedOutcome {
                for task in tasks {
                    await task.value
                }
            }
            try #require(drained != nil)

            let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("urn:xmpp:mam:2") })
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }

    struct SyncResurrectionGuard {
        /// Holds a MAM sync (spawned via `initial roster response`) suspended mid-round-trip so
        /// `beforeRelease` can mutate state — e.g. destroy the conversation — before the
        /// archive and `<fin>` land and the transcript appends run.
        @MainActor
        private func driveSyncWithHeldArchive(
            harness: MAMHarness,
            beforeRelease: (MAMHarness) async throws -> Void
        ) async throws {
            await harness.chatService.handleEvent(.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)), accountID: harness.accountID)

            // Wait for the in-flight MAM query directly rather than coupling to the handshake stanza count.
            let mamIQ = try #require(await harness.transport.waitForSent(matching: { $0.contains("urn:xmpp:mam:2") }))
            let iqID = try #require(extractIQID(from: mamIQ))
            let queryID = try #require(extractQueryID(from: mamIQ))

            // Capture the handle while the task is registered and blocked on `queryMessages`.
            let tasks = harness.chatService.takePendingTasks()

            try await beforeRelease(harness)

            await harness.transport.simulateReceive(groupArchive(queryID: queryID, archiveID: "arch-1", GroupArchiveSpec(
                fromNick: "bob", serverID: "R", stanzaID: "S", body: "hi room"
            )))
            await harness.transport.simulateReceive(
                "<iq type='result' id='\(iqID)' from='\(roomJID.description)'>"
                    + "<fin xmlns='urn:xmpp:mam:2' complete='true'>"
                    + "<set xmlns='http://jabber.org/protocol/rsm'><count>1</count></set></fin></iq>"
            )

            for task in tasks {
                await task.value
            }
        }

        @Test
        @MainActor
        func `recreated transcript is deleted when conversation destroyed mid-sync`() async throws {
            let harness = try await makeMAMHarness()

            try await driveSyncWithHeldArchive(harness: harness) { harness in
                try await harness.store.deleteConversation(harness.conversation.id)
            }

            let remaining = await harness.transcripts.messages.filter { $0.conversationID == harness.conversation.id }
            #expect(remaining.isEmpty)
            let wasDeleted = await harness.transcripts.deletedTranscriptConversationIDs.contains(harness.conversation.id)
            #expect(wasDeleted)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `surviving conversation keeps its synced transcript`() async throws {
            let harness = try await makeMAMHarness()

            try await driveSyncWithHeldArchive(harness: harness) { _ in }

            let remaining = await harness.transcripts.messages.filter { $0.conversationID == harness.conversation.id }
            #expect(!remaining.isEmpty)
            let wasDeleted = await harness.transcripts.deletedTranscriptConversationIDs.contains(harness.conversation.id)
            #expect(!wasDeleted)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `a sync writes the preview and leaves what changed on the row meanwhile`() async throws {
            let harness = try await makeMAMHarness()

            try await driveSyncWithHeldArchive(harness: harness) { harness in
                // What other handlers stored while the archive was on its way.
                try await harness.store.updateConversation(harness.conversation.id) {
                    $0.isMuted = true
                    $0.unreadCount = 3
                }
            }

            let stored = try #require(
                try await harness.store.fetchConversations(for: harness.accountID).first { $0.id == harness.conversation.id }
            )
            // Armed: the sync did write to the row.
            #expect(stored.lastMessagePreview != nil)
            #expect(stored.isMuted)
            #expect(stored.unreadCount == 3)
            await harness.accountService.disconnect(accountID: harness.accountID)
        }
    }
}

@MainActor
extension ChatServiceMAMTests {
    @Test(arguments: [false, true])
    static func `archive ingestion persists reply and attachments without live filter side effects`(outgoing: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let transcripts = FileTranscriptStore(baseDirectory: directory)
            let fetcher = CountingLinkPreviewFetcher()
            let preview = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())
            let harness = try await makeMAMHarness(
                filters: [StylingFilter(), EmojiFilter(), LinkDetectionFilter(), LinkPreviewFilter(previewService: preview)],
                transcriptStore: transcripts
            )
            let body = "*reply* :) https://example.com/image.png"
            let imported: [ChatMessage]
            do {
                imported = try await ingestArchives(harness: harness, finCount: 1) { queryID in
                    [groupArchive(queryID: queryID, archiveID: "archive-id", GroupArchiveSpec(
                        fromNick: outgoing ? "alice" : "bob", serverID: "trusted-id", stanzaID: "incoming-id", body: body,
                        metadataXML: "<reply xmlns='urn:xmpp:reply:0' id='original-id'/>"
                            + "<stanza-id xmlns='urn:xmpp:sid:0' by='attacker@example.com' id='forged-id'/>"
                            + "<x xmlns='jabber:x:oob'><url>https://example.com/image.png</url><desc>image</desc></x>"
                    ))]
                }
            } catch {
                await harness.accountService.disconnect(accountID: harness.accountID)
                throw error
            }
            await harness.accountService.disconnect(accountID: harness.accountID)
            let reloaded = FileTranscriptStore(baseDirectory: directory)
            let persisted = try #require(try await reloaded.fetchMessages(for: harness.conversation.id, before: nil, limit: 10).first)
            #expect(imported.map(\.id) == [persisted.id])
            #expect(persisted.replyToID == "original-id")
            #expect(persisted.stanzaID == "incoming-id")
            #expect(persisted.serverID == "trusted-id")
            #expect(persisted.isOutgoing == outgoing)
            #expect(persisted.body == body)
            #expect(persisted.htmlBody?.contains("<strong>reply</strong>") == true)
            let expectedTimestamp = try Date.ISO8601FormatStyle().parse("2026-02-28T10:00:00Z")
            #expect(persisted.timestamp == expectedTimestamp)
            #expect(persisted.attachments.first?.url == "https://example.com/image.png")
            #expect(persisted.attachments.first?.mimeType == "image/png")
            #expect(await fetcher.invocationCount == 0)
        }
    }
}

@MainActor
extension ChatServiceMAMTests {
    @Test
    static func `initial history sync survives roster save failure and ignores readbacks`() async throws {
        let harness = try await makeMAMHarness()
        let roster = RosterService(store: harness.store)
        let client = try #require(harness.accountService.connectedClient(for: harness.accountID))
        roster.beginSession(accountID: harness.accountID, sessionID: UUID(), client: client)
        await harness.store.failNextRosterApplications()
        let initial = XMPPEvent.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: "failed"))
        let application = roster.receiveRosterEvent(initial, accountID: harness.accountID)
        await harness.chatService.handleEvent(initial, accountID: harness.accountID)
        let queryTask = Task { await harness.transport.waitForSent(matching: { $0.contains("urn:xmpp:mam:2") }) }
        try #require(try await boundedOutcome { _ = await queryTask.value } != nil)
        let query = try #require(await queryTask.value)
        let queryID = try #require(extractIQID(from: query))
        let tasks = harness.chatService.takePendingTasks()
        #expect(tasks.count == 1)
        await application?.value
        #expect(try await harness.store.fetchAccounts().first?.rosterVersion == nil)
        await harness.transport.simulateReceive("<iq type='result' id='\(queryID)' from='\(roomJID)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>")
        for task in tasks {
            await task.value
        }
        await harness.transport.clearSentBytes()
        for id in ["command", "recovery", "resume"] {
            await harness.chatService.handleEvent(.rosterUpdated(RosterUpdate(receipt: 2, origin: .readback(id), contents: .snapshot([]), version: id)), accountID: harness.accountID)
        }
        #expect(harness.chatService.takePendingTasks().isEmpty)
        #expect(await harness.transport.sentBytes.isEmpty)
        roster.purgeAccount(harness.accountID)
        for task in roster.takePendingTasks() {
            await task.value
        }
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
