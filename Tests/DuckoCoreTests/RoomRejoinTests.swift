import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let bookmarkedRoomJID = BareJID(localPart: "bookmarked", domainPart: "conference.example.com")!
private let leftRoomJID = BareJID(localPart: "left", domainPart: "conference.example.com")!

@MainActor
private func makeChatService(store: MockPersistenceStore) -> ChatService {
    ChatService(store: store, transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
}

private func storedRoom(_ room: BareJID, in store: MockPersistenceStore, accountID: UUID) async throws -> Conversation? {
    try await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
}

private func isJoinPresence(_ stanza: String) -> Bool {
    stanza.contains("<presence") && stanza.contains("/alice")
}

private func makeRoom(_ jid: BareJID, accountID: UUID, rejoinsOnConnect: Bool) -> Conversation {
    Conversation(
        id: UUID(), accountID: accountID, jid: jid, type: .groupchat,
        isPinned: false, isMuted: false, unreadCount: 0,
        roomNickname: "alice", rejoinsOnConnect: rejoinsOnConnect, createdAt: Date()
    )
}

/// A connected account whose client can join rooms, with the bookmarks service wired to the chat service.
@MainActor
private struct RejoinHarness {
    let store: MockPersistenceStore
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let bookmarksService: BookmarksService
    let accountID: UUID

    func rejoinsOnConnect(_ room: BareJID) async throws -> Bool? {
        try await storedRoom(room, in: store, accountID: accountID)?.rejoinsOnConnect
    }

    func joinPresences() async -> [String] {
        await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter(isJoinPresence)
    }
}

@MainActor
private func makeRejoinHarness() async throws -> RejoinHarness {
    let store = MockPersistenceStore()
    let transport = MockTransport()
    let factory = MockXMPPClientFactory(transport: transport, modules: [MUCModule(), PEPModule()])
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let chatService = makeChatService(store: store)
    chatService.setAccountService(accountService)
    let bookmarksService = BookmarksService()
    bookmarksService.setAccountService(accountService)
    bookmarksService.setChatService(chatService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value

    return RejoinHarness(
        store: store, transport: transport, accountService: accountService,
        chatService: chatService, bookmarksService: bookmarksService, accountID: accountID
    )
}

enum RoomRejoinTests {
    struct Remembering {
        @Test(arguments: [true, false])
        @MainActor
        func `a join is remembered unless it is a visit`(remember: Bool) async throws {
            let harness = try await makeRejoinHarness()
            let accountID = harness.accountID
            let chatService = harness.chatService

            let join = Task { @MainActor in
                try await chatService.joinRoomAwaitingEcho(jid: roomJID, nickname: "alice", accountID: accountID, remember: remember)
            }
            _ = await harness.transport.waitForSent(matching: isJoinPresence)
            let occupancy = RoomOccupancy(
                nickname: "alice",
                occupants: [RoomOccupant(nickname: "alice", affiliation: .member, role: .participant)],
                subject: nil
            )
            await chatService.handleEvent(.roomJoined(room: roomJID, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)
            try await join.value

            #expect(try await harness.rejoinsOnConnect(roomJID) == remember)

            await harness.accountService.disconnect(accountID: accountID)
        }

        @Test(arguments: [true, false])
        @MainActor
        func `leaving forgets the room unless it ends a visit`(forget: Bool) async throws {
            let harness = try await makeRejoinHarness()
            await harness.store.addConversation(makeRoom(roomJID, accountID: harness.accountID, rejoinsOnConnect: true))

            try await harness.chatService.leaveRoom(jid: roomJID, accountID: harness.accountID, forget: forget)

            #expect(try await harness.rejoinsOnConnect(roomJID) == !forget)

            await harness.accountService.disconnect(accountID: harness.accountID)
        }

        @Test
        @MainActor
        func `leaving while offline still keeps the room from being joined again`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)
            await store.addConversation(makeRoom(roomJID, accountID: testAccountID, rejoinsOnConnect: true))

            await #expect(throws: ChatService.ChatServiceError.self) {
                try await service.leaveRoom(jid: roomJID, accountID: testAccountID)
            }

            #expect(try await storedRoom(roomJID, in: store, accountID: testAccountID)?.rejoinsOnConnect == false)
        }

        @Test(arguments: [
            (OccupantLeaveReason.kicked(reason: nil), false),
            (.banned(reason: nil), false),
            (.affiliationChanged(reason: nil), false),
            (.serviceShutdown, true),
            (nil, true)
        ] as [(OccupantLeaveReason?, Bool)])
        @MainActor
        func `only being thrown out of a room forgets it`(reason: OccupantLeaveReason?, staysRemembered: Bool) async throws {
            let room = try await roomAfterOccupantLeft(nickname: "alice", reason: reason)

            #expect(room.rejoinsOnConnect == staysRemembered)
        }

        @Test
        @MainActor
        func `someone else being removed changes nothing`() async throws {
            let room = try await roomAfterOccupantLeft(nickname: "bob", reason: .kicked(reason: nil))

            #expect(room.rejoinsOnConnect)
        }

        @MainActor
        private func roomAfterOccupantLeft(nickname: String, reason: OccupantLeaveReason?) async throws -> Conversation {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store)
            await store.addConversation(makeRoom(roomJID, accountID: testAccountID, rejoinsOnConnect: true))

            let occupant = RoomOccupant(nickname: nickname, affiliation: .none, role: .none)
            await service.handleEvent(.roomOccupantLeft(room: roomJID, occupant: occupant, reason: reason), accountID: testAccountID)

            return try #require(try await storedRoom(roomJID, in: store, accountID: testAccountID))
        }
    }

    struct RejoinOnConnect {
        @Test(arguments: [true, false])
        @MainActor
        func `a connect joins again the remembered rooms that no auto-join bookmark covers`(autoJoinEnabled: Bool) async throws {
            let harness = try await makeRejoinHarness()
            let accountID = harness.accountID
            await harness.store.addConversation(makeRoom(roomJID, accountID: accountID, rejoinsOnConnect: true))
            await harness.store.addConversation(makeRoom(bookmarkedRoomJID, accountID: accountID, rejoinsOnConnect: true))
            await harness.store.addConversation(makeRoom(leftRoomJID, accountID: accountID, rejoinsOnConnect: false))
            harness.bookmarksService.autoJoinEnabled = autoJoinEnabled
            let bookmarksService = harness.bookmarksService

            let boundJID = try #require(FullJID.parse("\(testJIDString)/test"))
            let connected = Task { @MainActor in
                await bookmarksService.handleEvent(.connected(boundJID), accountID: accountID)
            }
            try await answerBookmarksFetch(on: harness.transport, autoJoin: [bookmarkedRoomJID])
            await connected.value

            let joined = await harness.joinPresences()
            let expectedJoins = autoJoinEnabled ? 1 : 0
            #expect(joined.count == 2 * expectedJoins)
            #expect(joined.count { $0.contains("\(bookmarkedRoomJID)/alice") } == expectedJoins)
            #expect(joined.count { $0.contains("\(roomJID)/alice") } == expectedJoins)

            await harness.accountService.disconnect(accountID: accountID)
        }
    }
}
