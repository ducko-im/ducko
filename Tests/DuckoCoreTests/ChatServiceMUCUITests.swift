import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let testAccountJID = BareJID(localPart: "user", domainPart: "example.com")!
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

// MARK: - Tests

enum ChatServiceMUCUITests {
    struct RoomParticipantsSeeding {
        @Test
        @MainActor
        func `roomJoined seeds roomParticipants`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "admin", affiliation: .admin, role: .moderator)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            let participants = service.participants(forRoomJIDString: testRoomJID.description, accountID: testAccountID)
            #expect(participants.count == 2)
            #expect(participants.contains { $0.nickname == "me" })
            #expect(participants.contains { $0.nickname == "admin" })
        }
    }

    struct OccupantJoined {
        @Test
        @MainActor
        func `roomOccupantJoined adds to roomParticipants`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Seed with initial occupancy
            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            // New occupant joins
            let newOccupant = RoomOccupant(nickname: "newcomer", affiliation: .none, role: .participant)
            await service.handleEvent(.roomOccupantJoined(room: testRoomJID, occupant: newOccupant), accountID: testAccountID)

            let participants = service.participants(forRoomJIDString: testRoomJID.description, accountID: testAccountID)
            #expect(participants.count == 2)
            #expect(participants.contains { $0.nickname == "newcomer" })

            // Verify mapped affiliation and role
            let newcomer = participants.first { $0.nickname == "newcomer" }
            #expect(newcomer?.affiliation == RoomAffiliation.none)
            #expect(newcomer?.role == RoomRole.participant)
        }
    }

    struct OccupantLeft {
        @Test
        @MainActor
        func `roomOccupantLeft removes from roomParticipants`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            // Seed with two occupants
            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "me", affiliation: .member, role: .participant),
                    RoomOccupant(nickname: "other", affiliation: .member, role: .participant)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            // Other leaves
            let leftOccupant = RoomOccupant(nickname: "other", affiliation: .member, role: .participant)
            await service.handleEvent(.roomOccupantLeft(room: testRoomJID, occupant: leftOccupant, reason: nil, isSelf: false), accountID: testAccountID)

            let participants = service.participants(forRoomJIDString: testRoomJID.description, accountID: testAccountID)
            #expect(participants.count == 1)
            #expect(participants.contains { $0.nickname == "other" } == false)
        }
    }

    struct ParticipantGrouping {
        @Test
        @MainActor
        func `participantGroups groups and sorts by affiliation`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let occupancy = RoomOccupancy(
                nickname: "me",
                occupants: [
                    RoomOccupant(nickname: "user1", affiliation: .none, role: .participant),
                    RoomOccupant(nickname: "owner1", affiliation: .owner, role: .moderator),
                    RoomOccupant(nickname: "admin1", affiliation: .admin, role: .moderator),
                    RoomOccupant(nickname: "member1", affiliation: .member, role: .participant)
                ],
                subject: nil
            )
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            let groups = service.participantGroups(forRoomJIDString: testRoomJID.description, accountID: testAccountID)
            #expect(groups.count == 4)
            #expect(groups[0].affiliation == .owner)
            #expect(groups[1].affiliation == .admin)
            #expect(groups[2].affiliation == .member)
            #expect(groups[3].affiliation == .none)
        }
    }

    struct InviteReceived {
        @Test
        @MainActor
        func `roomInviteReceived appends to pendingInvites`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let invite = RoomInvite(
                room: testRoomJID,
                from: .bare(testAccountJID),
                reason: "Join us!",
                password: nil
            )
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)

            #expect(service.pendingInvites.count == 1)
            #expect(service.pendingInvites[0].roomJIDString == testRoomJID.description)
            #expect(service.pendingInvites[0].reason == "Join us!")
            #expect(service.pendingInvites[0].isDirect == false)
        }

        @Test
        @MainActor
        func `Direct invite sets isDirect on pendingInvite`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let invite = RoomInvite(
                room: testRoomJID,
                from: .bare(testAccountJID),
                isDirect: true
            )
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)

            #expect(service.pendingInvites.count == 1)
            #expect(service.pendingInvites[0].isDirect == true)
        }

        @Test
        @MainActor
        func `Duplicate invites are deduplicated`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let invite = RoomInvite(room: testRoomJID, from: .bare(testAccountJID))
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)

            #expect(service.pendingInvites.count == 1)
        }
    }

    struct DeclineInvite {
        @Test
        @MainActor
        func `declineInvite removes from pendingInvites`() async throws {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let invite = RoomInvite(room: testRoomJID, from: .bare(testAccountJID))
            await service.handleEvent(.roomInviteReceived(invite), accountID: testAccountID)
            #expect(service.pendingInvites.count == 1)

            try await service.declineInvite(service.pendingInvites[0], accountID: testAccountID)
            #expect(service.pendingInvites.isEmpty)
        }
    }

    struct MapOccupantValues {
        @Test
        @MainActor
        func `mapOccupant correctly maps all affiliation/role values`() async {
            let store = makeStore()
            let transcripts = makeTranscripts()
            let service = makeChatService(store: store, transcripts: transcripts)

            let occupants = [
                RoomOccupant(nickname: "o", jid: testAccountJID, affiliation: .owner, role: .moderator),
                RoomOccupant(nickname: "a", affiliation: .admin, role: .participant),
                RoomOccupant(nickname: "m", affiliation: .member, role: .visitor),
                RoomOccupant(nickname: "x", affiliation: .outcast, role: .none),
                RoomOccupant(nickname: "n", affiliation: .none, role: .none)
            ]
            let occupancy = RoomOccupancy(nickname: "o", occupants: occupants, subject: nil)
            await service.handleEvent(.roomJoined(room: testRoomJID, occupancy: occupancy, isNewlyCreated: false), accountID: testAccountID)

            let participants = service.participants(forRoomJIDString: testRoomJID.description, accountID: testAccountID)

            let owner = participants.first { $0.nickname == "o" }
            #expect(owner?.affiliation == .owner)
            #expect(owner?.role == .moderator)
            #expect(owner?.jidString == testAccountJID.description)

            let admin = participants.first { $0.nickname == "a" }
            #expect(admin?.affiliation == .admin)
            #expect(admin?.role == .participant)

            let member = participants.first { $0.nickname == "m" }
            #expect(member?.affiliation == .member)
            #expect(member?.role == .visitor)

            let outcast = participants.first { $0.nickname == "x" }
            #expect(outcast?.affiliation == RoomAffiliation.outcast)
            #expect(outcast?.role == RoomRole.none)

            let noneParticipant = participants.first { $0.nickname == "n" }
            #expect(noneParticipant?.affiliation == RoomAffiliation.none)
            #expect(noneParticipant?.role == RoomRole.none)
        }
    }
}
