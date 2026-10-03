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

/// Connected ChatService bundle pre-seeded with a groupchat conversation (nickname `alice`), used to drive
/// `fetchServerHistory` against simulated MAM archives.
@MainActor
private struct GroupMAMHarness {
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let conversation: Conversation
    let accountID: UUID
}

@MainActor
private func makeGroupMAMHarness(filters: [any MessageFilter] = [], transcriptStore: (any TranscriptStore)? = nil) async throws -> GroupMAMHarness {
    let store = makeStore()
    let transcripts = makeTranscripts()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: [MAMModule()])
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
        id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
        isPinned: false, isMuted: false, unreadCount: 0,
        roomNickname: "alice", createdAt: Date()
    )
    try await store.upsertConversation(conversation)

    return GroupMAMHarness(
        store: store, transcripts: transcripts, transport: transport,
        accountService: accountService, chatService: chatService,
        conversation: conversation, accountID: accountID
    )
}

/// Drives `fetchServerHistory(jid: roomJID)`, feeds the archive stanzas built from the captured queryid,
/// then a complete `fin`, and returns the newly imported messages.
@MainActor
private func ingestArchives(
    harness: GroupMAMHarness,
    finCount: Int,
    archives: (_ queryID: String) -> [String]
) async throws -> [ChatMessage] {
    let fetchTask = Task { @MainActor in
        try await harness.chatService.fetchServerHistory(
            jid: roomJID, accountID: harness.accountID, before: nil, limit: 50
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
    await harness.transport.simulateReceive(
        "<iq type='result' id='\(iqID)' from='\(roomJID.description)'>"
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
        + "<body>\(spec.body)</body>"
        + encryptedElement
        + spec.metadataXML
        + "<stanza-id xmlns='urn:xmpp:sid:0' id='\(spec.serverID)' by='\(roomJID.description)'/>"
        + "</message></forwarded></result></message>"
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

    struct OwnMUCMAMDedup {
        @Test
        @MainActor
        func `own plaintext MUC message is not double-imported on MAM replay`() async throws {
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness()
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
            let harness = try await makeGroupMAMHarness(filters: [StylingFilter()])

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
            let harness = try await makeGroupMAMHarness(filters: [EmojiFilter()])

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
            let harness = try await makeGroupMAMHarness(
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

    struct SyncResurrectionGuard {
        /// Holds a MAM sync (spawned via `initial roster response`) suspended mid-round-trip so
        /// `beforeRelease` can mutate state — e.g. destroy the conversation — before the
        /// archive and `<fin>` land and the transcript appends run.
        @MainActor
        private func driveSyncWithHeldArchive(
            harness: GroupMAMHarness,
            beforeRelease: (GroupMAMHarness) async throws -> Void
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
            let harness = try await makeGroupMAMHarness()

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
            let harness = try await makeGroupMAMHarness()

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
            let harness = try await makeGroupMAMHarness()

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

extension ChatServiceMAMTests {
    @Test(arguments: [false, true])
    @MainActor
    static func `archive ingestion persists reply and attachments without live filter side effects`(outgoing: Bool) async throws {
        try await withTemporaryDirectory { directory in
            let transcripts = FileTranscriptStore(baseDirectory: directory)
            let fetcher = CountingLinkPreviewFetcher()
            let preview = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())
            let harness = try await makeGroupMAMHarness(
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

extension ChatServiceMAMTests {
    @Test
    @MainActor
    static func `initial history sync survives roster save failure and ignores readbacks`() async throws {
        let harness = try await makeGroupMAMHarness()
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
