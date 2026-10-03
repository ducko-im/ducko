import DuckoTestSupport
import DuckoXMPP
import Foundation
import Observation
import Synchronization
import Testing
@testable import DuckoCore
@testable import DuckoUI

@MainActor
struct ChatWindowStateTests {
    private static let jidString = "bob@example.com"

    private struct Fixture {
        let windowState: ChatWindowState
        let environment: AppEnvironment
        let store: MockPersistenceStore
        let transcripts: MockTranscriptStore
        let accountID: UUID
    }

    private static func makeFixture(
        jidString: String = jidString, type: Conversation.ConversationType = .chat
    ) async throws -> Fixture {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let jid = try #require(BareJID.parse(jidString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(
            id: UUID(),
            jid: aliceJID,
            isEnabled: true,
            connectOnLaunch: false,
            createdAt: Date()
        )
        await store.addAccount(account)
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: jid,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        ))
        let environment = AppEnvironment(
            store: store,
            transcripts: transcripts,
            credentialStore: NullCredentialStore()
        )
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: jidString, accountID: account.id, environment: environment)
        await windowState.load()
        return Fixture(windowState: windowState, environment: environment, store: store, transcripts: transcripts, accountID: account.id)
    }

    @Test func `windowState carries the opened accountID`() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.windowState.accountID == fixture.accountID)
    }

    @Test func `commandTarget offers contact info for a 1:1 chat`() async throws {
        let fixture = try await Self.makeFixture()
        let target = try #require(fixture.windowState.commandTarget)
        #expect(target.contactInfoRef == ContactInfoRef(accountID: fixture.accountID, jid: Self.jidString))
    }

    @Test(arguments: [(type: Conversation.ConversationType.groupchat, occupant: String?.none), (type: .chat, occupant: "nick")])
    func `commandTarget offers no contact info for a room or a MUC private message`(
        conversation: (type: Conversation.ConversationType, occupant: String?)
    ) throws {
        let environment = AppEnvironment(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore())
        let accountID = UUID()
        let jidString = conversation.occupant.map { "room@conference.example.com/\($0)" } ?? "room@conference.example.com"
        let windowState = ChatWindowState(jidString: jidString, accountID: accountID, environment: environment)
        windowState.conversation = try Conversation(
            id: UUID(), accountID: accountID, jid: #require(BareJID.parse("room@conference.example.com")), type: conversation.type,
            isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: conversation.occupant, createdAt: Date()
        )

        let target = try #require(windowState.commandTarget)

        #expect(target.contactInfoRef == nil)
        #expect(target.chatKey == ConversationKey(accountID: accountID, jid: jidString))
    }

    @Test func `windowState resolves the contact under its own account when the JID is on two`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let peerJID = try #require(BareJID.parse(Self.jidString))
        let accountA = try Account(id: UUID(), jid: #require(BareJID.parse("a@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        let accountB = try Account(id: UUID(), jid: #require(BareJID.parse("b@example.com")), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(accountA)
        await store.addAccount(accountB)

        // Same peer JID rostered on both accounts with distinct names.
        try await store.upsertContact(Contact(id: UUID(), accountID: accountA.id, jid: peerJID, name: "Bob-A", subscription: .both, groups: [], isBlocked: false, createdAt: Date()))
        try await store.upsertContact(Contact(id: UUID(), accountID: accountB.id, jid: peerJID, name: "Bob-B", subscription: .both, groups: [], isBlocked: false, createdAt: Date()))

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        try await environment.rosterService.loadContacts(for: accountA.id)
        try await environment.rosterService.loadContacts(for: accountB.id)

        let windowState = ChatWindowState(jidString: Self.jidString, accountID: accountB.id, environment: environment)
        await windowState.load()

        #expect(windowState.accountID == accountB.id)
        #expect(windowState.contact?.name == "Bob-B")
    }

    @Test func `loadOlderMessages sets lastLoadHistoryError when server fetch fails`() async throws {
        let fixture = try await Self.makeFixture()
        #expect(fixture.windowState.lastLoadHistoryError == nil)

        // No connected client → `fetchServerHistory` throws `ChatServiceError.notConnected`.
        await fixture.windowState.loadOlderMessages()

        #expect(fixture.windowState.lastLoadHistoryError != nil)
    }

    @Test func `clearLoadHistoryError resets the error state`() async throws {
        let fixture = try await Self.makeFixture()
        await fixture.windowState.loadOlderMessages()
        try #require(fixture.windowState.lastLoadHistoryError != nil)

        fixture.windowState.clearLoadHistoryError()

        #expect(fixture.windowState.lastLoadHistoryError == nil)
    }

    @Test func `loadOlderMessages clears prior lastLoadHistoryError on success`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.windowState.lastLoadHistoryError = "stale error"

        let conversationID = try #require(fixture.windowState.conversation?.id)
        let message = ChatMessage(
            id: UUID(),
            conversationID: conversationID,
            fromJID: Self.jidString,
            body: "older",
            timestamp: Date(timeIntervalSinceNow: -3600),
            isOutgoing: false,
            isDelivered: true,
            isEdited: false,
            type: "chat"
        )
        try await fixture.transcripts.appendMessage(message)

        await fixture.windowState.loadOlderMessages()

        #expect(fixture.windowState.lastLoadHistoryError == nil)
        #expect(fixture.windowState.messages.contains { $0.body == "older" })
    }

    @Test func `sendMessage captures typed ChatService errors and preserves body`() async throws {
        let fixture = try await Self.makeFixture()
        let typed = "Reach for the sky"

        // No connected client → `sendMessage` flows through the
        // `ChatService.ChatServiceError.notConnected` catch arm.
        await fixture.windowState.sendMessage(typed)

        #expect(fixture.windowState.lastSendError != nil)
        #expect(fixture.windowState.lastFailedSendBody == typed)
    }

    @Test func `clearSendError resets lastSendError`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.windowState.lastSendError = "Send failed: invalid JID"
        try #require(fixture.windowState.lastSendError != nil)

        fixture.windowState.clearSendError()

        #expect(fixture.windowState.lastSendError == nil)
    }

    @Test func `roomSubject reflects a live service-side change, not the stale load-time copy`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let roomJIDString = "room@conference.example.com"
        let roomJID = try #require(BareJID.parse(roomJIDString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(id: UUID(), jid: aliceJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        ))

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: roomJIDString, accountID: account.id, environment: environment)
        await windowState.load()
        #expect(windowState.roomSubject == nil)

        // A server-driven subject change updates the service's published cache.
        await environment.chatService.handleEvent(
            .roomSubjectChanged(room: roomJID, subject: "Daily standup", setter: nil),
            accountID: account.id
        )

        // roomSubject must read the live cache, while the frozen load-time copy stays nil.
        #expect(windowState.roomSubject == "Daily standup")
        #expect(windowState.conversation?.roomSubject == nil)
    }

    @Test func `displayName reflects a live service-side change, not the stale load-time copy`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let roomJIDString = "room@conference.example.com"
        let roomJID = try #require(BareJID.parse(roomJIDString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(id: UUID(), jid: aliceJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        let seeded = Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            displayName: "Old Room Name",
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
        await store.addConversation(seeded)

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: roomJIDString, accountID: account.id, environment: environment)
        await windowState.load()
        #expect(windowState.displayName == "Old Room Name")

        // A server-driven rename lands in the store; republishing refreshes the live cache.
        var renamed = seeded
        renamed.displayName = "New Room Name"
        try await store.upsertConversation(renamed)
        try await environment.chatService.loadConversations(for: account.id)

        // displayName must read the live cache, while the frozen load-time copy stays stale.
        #expect(windowState.displayName == "New Room Name")
        #expect(windowState.conversation?.displayName == "Old Room Name")
    }

    @Test func `myRoomRole resolves from the live roomNickname, not the stale load-time copy`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let roomJIDString = "room@conference.example.com"
        let roomJID = try #require(BareJID.parse(roomJIDString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(id: UUID(), jid: aliceJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        await store.addConversation(Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            roomNickname: "me",
            createdAt: Date()
        ))

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()

        // Seed occupancy so "me" is a known moderator, then load so liveConversation resolves.
        await environment.chatService.handleEvent(
            .roomJoined(
                room: roomJID,
                occupancy: RoomOccupancy(
                    nickname: "me",
                    occupants: [RoomOccupant(nickname: "me", affiliation: .owner, role: .moderator)],
                    subject: nil
                ),
                isNewlyCreated: false
            ),
            accountID: account.id
        )
        let windowState = ChatWindowState(jidString: roomJIDString, accountID: account.id, environment: environment)
        await windowState.load()
        #expect(windowState.myRoomRole == .moderator)

        // A self-nick change renames the participant and spawns a deferred update of the
        // live conversation's roomNickname; the frozen load-time copy is untouched.
        await environment.chatService.handleEvent(
            .roomOccupantNickChanged(
                room: roomJID,
                oldNickname: "me",
                occupant: RoomOccupant(nickname: "me2", affiliation: .owner, role: .moderator)
            ),
            accountID: account.id
        )
        let pending = environment.chatService.takePendingTasks()
        #expect(!pending.isEmpty)
        for task in pending {
            await task.value
        }

        // The live path resolves the renamed "me2" to its participant; a regression reading
        // the frozen "me" would match no participant and yield nil.
        #expect(windowState.myRoomRole == .moderator)
        #expect(windowState.conversation?.roomNickname == "me")
    }

    @Test func `displayName retains the last-known value after the conversation leaves openConversations`() async throws {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let roomJIDString = "room@conference.example.com"
        let roomJID = try #require(BareJID.parse(roomJIDString))
        let aliceJID = try #require(BareJID.parse("alice@example.com"))
        let account = Account(id: UUID(), jid: aliceJID, isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        let seeded = Conversation(
            id: UUID(),
            accountID: account.id,
            jid: roomJID,
            type: .groupchat,
            displayName: "Room Name",
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            roomSubject: "Daily standup",
            createdAt: Date()
        )
        await store.addConversation(seeded)

        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        try await environment.accountService.loadAccounts()
        let windowState = ChatWindowState(jidString: roomJIDString, accountID: account.id, environment: environment)
        await windowState.load()
        #expect(windowState.displayName == "Room Name")
        #expect(windowState.roomSubject == "Daily standup")

        // Evict the conversation from the live cache; the frozen value-type copy is untouched.
        try await store.deleteConversation(seeded.id)
        try await environment.chatService.loadConversations(for: account.id)

        // displayName falls back to the frozen copy, while roomSubject (no fallback) goes nil.
        #expect(windowState.displayName == "Room Name")
        #expect(windowState.roomSubject == nil)
    }

    // MARK: - Attachments

    private static func incomingTransfer(
        from peer: String, accountID: UUID, state: FileTransferService.TransferState = .transferring(progress: 0.5),
        direction: FileTransferService.TransferDirection = .incoming
    ) -> FileTransferService.ActiveTransfer {
        .init(
            id: UUID(), accountID: accountID, fileName: "photo.png", fileSize: 3,
            state: state, method: .jingle, direction: direction, sid: UUID().uuidString, peerJIDString: peer
        )
    }

    @Test func `queued files go the way that was chosen, and a new batch starts with upload again`() async throws {
        let fixture = try await Self.makeFixture()
        let windowState = fixture.windowState
        try await withTemporaryDirectory { directory in
            let fileURL = directory.appendingPathComponent("notes.txt")
            try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

            // Upload, the choice every batch starts with: this account is not connected, so the composer says so and
            // the chat gets no row.
            windowState.addAttachment(url: fileURL)
            #expect(!windowState.sendsAttachmentsDirectly)
            await windowState.sendAttachments()
            #expect(windowState.lastSendError != nil)
            #expect(await fixture.transcripts.messages.isEmpty)

            // Directly: the file gets its row, which carries the reason once no device turns out to take it.
            windowState.addAttachment(url: fileURL)
            windowState.sendsAttachmentsDirectly = true
            windowState.addAttachment(url: fileURL)
            #expect(windowState.sendsAttachmentsDirectly)
            await windowState.sendAttachments()
            #expect(windowState.lastSendError == nil)
            let rows = await fixture.transcripts.messages
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.isOutgoing && $0.attachments.first?.localFileURL == fileURL })
            try await waitUntil { fixture.environment.fileTransferService.activeTransfers.allSatisfy { transfer in
                if case .failed = transfer.state { true } else { false }
            } }

            windowState.addAttachment(url: fileURL)
            #expect(!windowState.sendsAttachmentsDirectly)
        }
    }

    @Test func `a direct send that cannot start says so in the composer`() async throws {
        let fixture = try await Self.makeFixture()
        let windowState = fixture.windowState
        windowState.addAttachment(url: URL(fileURLWithPath: "/nonexistent/notes.txt"))
        windowState.sendsAttachmentsDirectly = true

        await windowState.sendAttachments()

        #expect(windowState.lastSendError?.hasPrefix("Could not read the file") == true)
        #expect(await fixture.transcripts.messages.isEmpty)
    }

    @Test func `only files the chat's own contact is sending right now get a receiving row`() async throws {
        let fixture = try await Self.makeFixture()
        let service = fixture.environment.fileTransferService
        let receiving = Self.incomingTransfer(from: Self.jidString, accountID: fixture.accountID)
        service.registerTransferForTesting(receiving)
        service.registerTransferForTesting(Self.incomingTransfer(from: "carol@example.com", accountID: fixture.accountID))
        service.registerTransferForTesting(Self.incomingTransfer(from: Self.jidString, accountID: UUID()))
        service.registerTransferForTesting(Self.incomingTransfer(from: Self.jidString, accountID: fixture.accountID, state: .awaitingAcceptance))
        service.registerTransferForTesting(Self.incomingTransfer(from: Self.jidString, accountID: fixture.accountID, direction: .outgoing))

        #expect(fixture.windowState.receivingTransfers.map(\.id) == [receiving.id])
    }

    @Test func `a room gets no receiving row for a file one of its occupants is sending`() async throws {
        let roomJIDString = "room@conference.example.com"
        let fixture = try await Self.makeFixture(jidString: roomJIDString, type: .groupchat)
        // Armed: the tab is the room's own chat.
        try #require(fixture.windowState.conversation?.type == .groupchat)
        // An occupant's bare JID is the room's.
        fixture.environment.fileTransferService.registerTransferForTesting(
            Self.incomingTransfer(from: roomJIDString, accountID: fixture.accountID)
        )

        #expect(fixture.windowState.receivingTransfers.isEmpty)
    }

    @Test func `the note that files are not encrypted follows a switch made while the chat is open`() async throws {
        let fixture = try await Self.makeFixture()
        let conversationID = try #require(fixture.windowState.conversation?.id)
        #expect(!fixture.windowState.sendsFilesUnencryptedInEncryptedChat)

        // Encryption is switched on after the tab loaded its own copy of the chat.
        try await fixture.environment.chatService.setEncryptionEnabled(true, for: conversationID, accountID: fixture.accountID)

        #expect(fixture.windowState.sendsFilesUnencryptedInEncryptedChat)
    }

    // MARK: - Notes

    @Test func `a chat's timeline notes are loaded with its messages`() async throws {
        let fixture = try await Self.makeFixture()
        let conversationID = try #require(fixture.windowState.conversation?.id)
        let note = TimelineNote(conversationID: conversationID, kind: .encryptionEnabledByContact)
        try await fixture.transcripts.appendNote(note)

        await fixture.windowState.refreshMessages()

        #expect(fixture.windowState.notes == [note])
        #expect(fixture.windowState.timelineItems.map(\.id) == [note.id])
    }

    @Test func `opening a chat loads the notes from its oldest loaded message on`() async throws {
        let fixture = try await Self.makeFixture()
        let conversationID = try #require(fixture.windowState.conversation?.id)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = TimelineNote(conversationID: conversationID, timestamp: start.addingTimeInterval(-10), kind: .encryptionEnabledByContact)
        let later = TimelineNote(conversationID: conversationID, timestamp: start.addingTimeInterval(10), kind: .encryptionEnabledByContact)
        try await fixture.transcripts.appendNote(earlier)
        try await fixture.transcripts.appendNote(later)
        await fixture.transcripts.addMessage(ChatMessage(
            id: UUID(), conversationID: conversationID, stanzaID: "m1", fromJID: Self.jidString, body: "hi",
            timestamp: start, isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
        ))

        let opened = ChatWindowState(jidString: Self.jidString, accountID: fixture.accountID, environment: fixture.environment)
        await opened.load()

        // A note older than everything loaded belongs with the older messages, which are not on screen yet.
        #expect(opened.notes == [later])
    }

    // MARK: - Link Previews

    @Test func `a link preview that arrives after the messages loaded redraws its bubble`() async throws {
        let fixture = try await Self.makeFixture()
        let conversationID = try #require(fixture.windowState.conversation?.id)
        let link = "https://example.com/page"
        let message = ChatMessage(
            id: UUID(), conversationID: conversationID, stanzaID: "m1", fromJID: Self.jidString, body: link,
            timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "chat"
        )
        await fixture.transcripts.addMessage(message)
        // As after a relaunch: the preview is stored, and nothing has read it into memory yet.
        try await fixture.store.upsertLinkPreview(LinkPreview(url: link, title: "Example", fetchedAt: Date()))

        let redrawn = Mutex(false)
        withObservationTracking {
            _ = fixture.windowState.linkPreview(for: message)
        } onChange: {
            redrawn.withLock { $0 = true }
        }
        await fixture.windowState.refreshMessages()
        try await waitUntil { redrawn.withLock { $0 } }

        #expect(fixture.windowState.linkPreview(for: message)?.title == "Example")
    }
}
