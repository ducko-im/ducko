import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// Pins two read-side gates: `AccountService.connectedClient(for:)` must surface
// `ChatServiceError.notConnected` (not the leaky `XMPPClientError.notConnected`)
// and `ChatService.normalizedRoomKey(_:)` must RFC 7622-lowercase user-typed
// room JID strings. Driven without a live transport.

private let testJID = BareJID(localPart: "alice", domainPart: "example.com")!
private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

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

enum ChatServiceConnectedClientGateTests {
    struct ConnectedClientGate {
        @Test
        @MainActor
        func `joinRoom on disconnected account throws notConnected`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let credentials = MockCredentialStore()
            let accountService = makeAccountService(store: store, credentials: credentials)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            // `createAccount` initializes `connectionStates[accountID] =
            // .disconnected` (per `loadAccounts`). No connect is driven, so
            // `connectedClient(for:)` must return nil and the join must throw
            // the service-layer `.notConnected` envelope.
            let accountID = try await accountService.createAccount(jidString: testJIDString)

            await #expect(throws: ChatService.ChatServiceError.self) {
                try await chatService.joinRoom(jid: testRoomJID, nickname: "me", accountID: accountID)
            }
        }

        @Test
        @MainActor
        func `sendMessage on disconnected account throws notConnected`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let credentials = MockCredentialStore()
            let accountService = makeAccountService(store: store, credentials: credentials)
            let chatService = makeChatService(store: store, transcripts: transcripts)
            chatService.setAccountService(accountService)

            // `sendMessage` checks `connectedClient` before any transcript work, so the gate fires for an account
            // that never connected. `sendCorrection` and `retractMessage` check the stored conversation and the
            // original message first, so reaching their gate needs both staged.
            let accountID = try await accountService.createAccount(jidString: testJIDString)

            await #expect(throws: ChatService.ChatServiceError.self) {
                try await chatService.sendMessage(to: testJID, body: "hi", accountID: accountID)
            }
        }

        @Test
        @MainActor
        func `joinRoom with no accountService throws notConnected`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let chatService = makeChatService(store: store, transcripts: transcripts)
            // Deliberately skip `setAccountService` — the weak reference stays nil.
            // `connectedClient(for:)` short-circuits via the optional chain
            // and the gate must still surface `.notConnected` rather than
            // silently returning.
            let accountID = UUID()

            await #expect(throws: ChatService.ChatServiceError.self) {
                try await chatService.joinRoom(jid: testRoomJID, nickname: "me", accountID: accountID)
            }
        }
    }

    struct NormalizedRoomKey {
        @Test
        @MainActor
        func `participants read with mixed case returns the lowercased entry`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountID = UUID()

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "admin", affiliation: .admin, role: .moderator)
                ],
                subject: nil
            )
            // `roomJoined` writes under `room.description` — RFC 7622-lowercased.
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)

            // Read-side normalization: a mixed-case JID-string (the shape a
            // user-typed `windowState.jidString` can take, e.g. an integration
            // test's `inttest-ui-FCA13B13@…` UUID-prefixed localpart) parses
            // into the same canonical key.
            let mixedCase = "Room@Conference.Example.Com"
            let participants = service.participants(forRoomJIDString: mixedCase, accountID: accountID)
            #expect(participants.count == 2)
            #expect(participants.contains { $0.nickname == "me" })
            #expect(participants.contains { $0.nickname == "admin" })
        }

        @Test
        @MainActor
        func `participants read with already-lowercased input returns same entry`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountID = UUID()

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)

            let participants = service.participants(forRoomJIDString: testRoomJID.description, accountID: accountID)
            #expect(participants.count == 1)
            #expect(participants.first?.nickname == "me")
        }

        @Test
        @MainActor
        func `participants read with malformed JID returns empty`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountID = UUID()

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)

            // A malformed JID string can't be parsed into a BareJID, so
            // `normalizedRoomKey` returns nil and `participants(forRoomJIDString:)`
            // short-circuits to `[]` rather than surfacing the room's
            // participants by accident via a raw-string fallback.
            let participants = service.participants(forRoomJIDString: "not a valid jid", accountID: accountID)
            #expect(participants.isEmpty)
        }

        @Test
        @MainActor
        func `knownRoomDomains returns the domain part of every joined room`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)
            let accountID = UUID()

            let secondRoom = try #require(BareJID(localPart: "lounge", domainPart: "muc.other.example"))
            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)
            await service.handleEvent(.roomJoined(room: secondRoom, occupancy: occupancy, isNewlyCreated: false), accountID: accountID)

            let domains = service.knownRoomDomains(accountID: accountID)
            #expect(domains.contains("conference.example.com"))
            #expect(domains.contains("muc.other.example"))
            #expect(domains.count == 2)
        }
    }
}
