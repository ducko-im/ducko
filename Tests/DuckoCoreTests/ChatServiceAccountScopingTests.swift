import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
private func makeChatService(store: MockPersistenceStore, transcripts: MockTranscriptStore) -> ChatService {
    ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
}

private func makeConversation(
    accountID: UUID, jid: BareJID, type: Conversation.ConversationType = .chat, lastMessageDate: Date? = nil,
    unreadCount: Int = 0, occupantNickname: String? = nil
) -> Conversation {
    Conversation(
        id: UUID(),
        accountID: accountID,
        jid: jid,
        type: type,
        isPinned: false,
        isMuted: false,
        lastMessageDate: lastMessageDate,
        unreadCount: unreadCount,
        occupantNickname: occupantNickname,
        createdAt: Date()
    )
}

private struct FetchFailure: Error {}

enum ChatServiceAccountScopingTests {
    struct ConversationCache {
        @Test
        @MainActor
        func `loading account B keeps account A's conversations in the published union`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let convA = try makeConversation(accountID: accountA, jid: #require(BareJID.parse("a-peer@example.com")))
            let convB = try makeConversation(accountID: accountB, jid: #require(BareJID.parse("b-peer@example.com")))
            await store.addConversation(convA)
            await store.addConversation(convB)

            try await service.loadConversations(for: accountA)
            #expect(service.openConversations.contains { $0.id == convA.id })

            // A wholesale-replace would drop A's conversations when B loads.
            try await service.loadConversations(for: accountB)
            #expect(service.openConversations.contains { $0.id == convA.id })
            #expect(service.openConversations.contains { $0.id == convB.id })
        }

        @Test
        @MainActor
        func `a failed fetch on one account leaves the other's slot intact`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let convA = try makeConversation(accountID: accountA, jid: #require(BareJID.parse("a-peer@example.com")))
            let convB = try makeConversation(accountID: accountB, jid: #require(BareJID.parse("b-peer@example.com")))
            await store.addConversation(convA)
            await store.addConversation(convB)
            try await service.loadConversations(for: accountA)
            try await service.loadConversations(for: accountB)

            // selectConversation takes the fallback-assign path; a failed fetch must not republish a stale union.
            await store.setFetchConversationsError(FetchFailure())
            await service.selectConversation(convB.id, accountID: accountB)

            #expect(service.openConversations.contains { $0.id == convA.id })
            #expect(service.openConversations.contains { $0.id == convB.id })
        }

        @Test
        @MainActor
        func `the published union is ordered most-recent-first across accounts`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            // Interleave recency across the two accounts so a per-account-only order would be wrong.
            let newest = try makeConversation(accountID: accountA, jid: #require(BareJID.parse("newest@example.com")), lastMessageDate: Date(timeIntervalSinceNow: -10))
            let middle = try makeConversation(accountID: accountB, jid: #require(BareJID.parse("middle@example.com")), lastMessageDate: Date(timeIntervalSinceNow: -20))
            let oldest = try makeConversation(accountID: accountA, jid: #require(BareJID.parse("oldest@example.com")), lastMessageDate: Date(timeIntervalSinceNow: -30))
            await store.addConversation(newest)
            await store.addConversation(middle)
            await store.addConversation(oldest)

            try await service.loadConversations(for: accountA)
            try await service.loadConversations(for: accountB)

            #expect(service.openConversations.map(\.id) == [newest.id, middle.id, oldest.id])
        }

        @Test
        @MainActor
        func `message-less conversations get a stable deterministic order across rebuilds`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            // No lastMessageDate (both collapse to .distantPast) and an identical createdAt, so only the
            // final `id.uuidString` tie-breaker decides the order — the tier guarding against
            // `Dictionary.values` reshuffle.
            let createdAt = Date(timeIntervalSince1970: 1_000_000)
            let convA = try Conversation(
                id: UUID(), accountID: accountA, jid: #require(BareJID.parse("a@example.com")),
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: createdAt
            )
            let convB = try Conversation(
                id: UUID(), accountID: accountB, jid: #require(BareJID.parse("b@example.com")),
                type: .chat, isPinned: false, isMuted: false, unreadCount: 0, createdAt: createdAt
            )
            await store.addConversation(convA)
            await store.addConversation(convB)

            try await service.loadConversations(for: accountA)
            try await service.loadConversations(for: accountB)

            let expected = [convA, convB].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
            #expect(service.openConversations.map(\.id) == expected)

            // A subsequent rebuild must reproduce the same order, not reshuffle.
            try await service.loadConversations(for: accountB)
            #expect(service.openConversations.map(\.id) == expected)
        }

        @Test
        @MainActor
        func `an incremental single-conversation write survives a rebuild from another account`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let room = try #require(BareJID.parse("room@conference.example.com"))

            let occupancy = RoomOccupancy(nickname: "me", occupants: [], subject: nil)
            await service.handleEvent(.roomJoined(room: room, occupancy: occupancy, isNewlyCreated: false), accountID: accountA)
            try await service.loadConversations(for: accountA)

            // Subject change routes through the per-account slot, not just the published union.
            await service.handleEvent(.roomSubjectChanged(room: room, subject: "New topic", setter: nil), accountID: accountA)

            // A rebuild triggered by another account's load must not resurrect the pre-subject value.
            try await store.addConversation(makeConversation(accountID: accountB, jid: #require(BareJID.parse("b-peer@example.com"))))
            try await service.loadConversations(for: accountB)

            let roomConv = service.openConversations.first { $0.jid == room && $0.accountID == accountA }
            #expect(roomConv?.roomSubject == "New topic")
        }
    }

    struct RoomStateScoping {
        @Test
        @MainActor
        func `the same room under two accounts keeps independent participant lists`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let room = try #require(BareJID.parse("room@conference.example.com"))

            let occupancyA = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil,
                flags: [.logged]
            )
            let occupancyB = RoomOccupancy(
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "other", affiliation: .member, role: .participant)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: room, occupancy: occupancyA, isNewlyCreated: false), accountID: accountA)
            await service.handleEvent(.roomJoined(room: room, occupancy: occupancyB, isNewlyCreated: false), accountID: accountB)

            #expect(service.participants(forRoomJIDString: room.description, accountID: accountA).count == 1)
            #expect(service.participants(forRoomJIDString: room.description, accountID: accountB).count == 2)
            // Flags are scoped too — only A joined with the logged flag.
            #expect(service.roomFlags(forRoomJIDString: room.description, accountID: accountA).contains(.logged))
            #expect(service.roomFlags(forRoomJIDString: room.description, accountID: accountB).isEmpty)
        }
    }

    struct TypingScoping {
        @Test
        @MainActor
        func `isPartnerTyping is true only for the account that received composing`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let peer = try #require(BareJID.parse("peer@example.com"))

            await service.handleEvent(.chatStateChanged(from: .bare(peer), state: .composing, messageType: .chat), accountID: accountA)

            #expect(service.isPartnerTyping(jidString: peer.description, accountID: accountA))
            #expect(!service.isPartnerTyping(jidString: peer.description, accountID: accountB))
        }
    }

    struct UnreadScoping {
        @Test
        @MainActor
        func `unreadCount reads only the account's 1-1 chat, not another account's, a private chat or a room`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let peer = try #require(BareJID.parse("peer@example.com"))
            let room = try #require(BareJID.parse("room@conference.example.com"))
            await store.addConversation(makeConversation(accountID: accountA, jid: peer, unreadCount: 2))
            await store.addConversation(makeConversation(accountID: accountB, jid: room, unreadCount: 3, occupantNickname: "peer"))
            await store.addConversation(makeConversation(accountID: accountA, jid: room, type: .groupchat, unreadCount: 4))
            try await service.loadConversations(for: accountA)
            try await service.loadConversations(for: accountB)

            #expect(service.unreadCount(jidString: peer.description, accountID: accountA) == 2)
            #expect(service.unreadCount(jidString: peer.description, accountID: accountB) == 0)
            #expect(service.unreadCount(jidString: room.description, accountID: accountB) == 0)
            #expect(service.unreadCount(jidString: room.description, accountID: accountA) == 0)
        }
    }

    struct RawMessageScoping {
        @Test
        @MainActor
        func `a groupchat on one account does not suppress a 1-1 message for the same JID on another`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let roomJID = try #require(BareJID.parse("room@conference.example.com"))

            // Account A occupies the room as a groupchat.
            await service.handleEvent(
                .roomJoined(room: roomJID, occupancy: RoomOccupancy(nickname: "me", occupants: [], subject: nil), isNewlyCreated: false),
                accountID: accountA
            )

            // Account B receives a plaintext 1:1 message from the same bare JID (full-JID sender). The
            // groupchat is A's, not B's, so `shouldSkipRawMessage`'s account-scoped predicate must NOT
            // suppress it.
            let fullJID = try #require(FullJID(bareJID: roomJID, resourcePart: "someone"))
            var message = XMPPMessage(type: .chat, to: .bare(roomJID), id: "raw-1")
            message.from = .full(fullJID)
            message.body = "delivered to B, not suppressed"
            await service.handleEvent(.messageReceived(message), accountID: accountB)

            #expect(service.openConversations.contains { $0.accountID == accountB && $0.jid == roomJID && $0.type == .chat })
        }
    }

    struct InviteScoping {
        @Test
        @MainActor
        func `the same room invite on two accounts is two pending entries, deduped within an account`() async throws {
            let store = MockPersistenceStore()
            let service = makeChatService(store: store, transcripts: MockTranscriptStore())
            let accountA = UUID()
            let accountB = UUID()
            let room = try #require(BareJID.parse("room@conference.example.com"))
            let inviter = try #require(BareJID.parse("inviter@example.com"))
            let invite = RoomInvite(room: room, from: .bare(inviter))

            await service.handleEvent(.roomInviteReceived(invite), accountID: accountA)
            await service.handleEvent(.roomInviteReceived(invite), accountID: accountB)
            #expect(service.pendingInvites.count == 2)

            // Same invite again on A is deduped.
            await service.handleEvent(.roomInviteReceived(invite), accountID: accountA)
            #expect(service.pendingInvites.count == 2)
        }
    }
}
