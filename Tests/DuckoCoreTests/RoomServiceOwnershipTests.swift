import DuckoTestSupport
import Foundation
import Observation
import Synchronization
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RoomServiceOwnershipTests {
    private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
    private let accountID = UUID()

    @Test(arguments: [false, true])
    func `room and account cleanup finish waiters without success`(wholeAccount: Bool) async {
        let chat = ChatService(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
        let otherAccount = UUID()
        let (_, stream) = chat.registerRoomJoinNotifier(jid: room, accountID: accountID)
        let (otherID, otherStream) = chat.registerRoomJoinNotifier(jid: room, accountID: otherAccount)
        if wholeAccount {
            chat.purgeAccount(accountID)
        } else {
            chat.clearRoomState(for: room, accountID: accountID)
        }
        #expect(!chat.roomJoinNotifiers.keys.contains { $0.accountID == accountID })
        #expect(chat.roomJoinNotifiers[RoomJoinKey(accountID: otherAccount, room: room)]?.id == otherID)
        #expect(await chat.awaitRoomJoinedEcho(stream: stream, timeout: .seconds(1)) == false)
        chat.clearRoomJoinNotifier(jid: room, accountID: otherAccount, id: otherID)
        #expect(await chat.awaitRoomJoinedEcho(stream: otherStream, timeout: .seconds(1)) == false)
    }

    @Test(arguments: [false, true])
    func `late joined persistence cannot restore cleared occupancy or resolve a replacement waiter`(replaceWaiter: Bool) async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let service = RoomService(
            store: MockPersistenceStore(),
            ensureConversation: { _, _, _ in await entered.signal(); await release.wait() },
            didUpdateConversation: { _ in }
        )
        let (_, originalStream) = service.registerRoomJoinNotifier(jid: room, accountID: accountID)
        let operation = Task {
            await service.handleRoomJoined(
                room: room,
                occupancy: RoomOccupancy(nickname: "me", occupants: [RoomOccupant(nickname: "me", affiliation: .member, role: .participant)], subject: nil),
                isNewlyCreated: true, accountID: accountID
            )
        }
        defer { operation.cancel(); Task { await release.signal() } }
        let arrived = try await boundedOutcome { await entered.wait() }
        try #require(arrived != nil)
        service.clearRoomState(for: room, accountID: accountID)
        let replacement = replaceWaiter ? service.registerRoomJoinNotifier(jid: room, accountID: accountID) : nil
        await release.signal()
        await operation.value
        #expect(service.participants(forRoomJIDString: room.description, accountID: accountID).isEmpty)
        #expect(!service.isRoomNewlyCreated(jidString: room.description, accountID: accountID))
        #expect(await service.awaitRoomJoinedEcho(stream: originalStream, timeout: .seconds(1)) == false)
        if let replacement {
            #expect(service.roomJoinNotifiers[RoomJoinKey(accountID: accountID, room: room)]?.id == replacement.id)
            service.clearRoomJoinNotifier(jid: room, accountID: accountID, id: replacement.id)
            #expect(await service.awaitRoomJoinedEcho(stream: replacement.stream, timeout: .seconds(1)) == false)
        }
    }

    @Test(arguments: [false, true])
    func `cancellation during joined persistence finishes the waiter without success`(cancel: Bool) async throws {
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let service = RoomService(
            store: MockPersistenceStore(),
            ensureConversation: { _, _, _ in await entered.signal(); await release.wait() },
            didUpdateConversation: { _ in }
        )
        let (notifierID, stream) = service.registerRoomJoinNotifier(jid: room, accountID: accountID)
        let operation = Task {
            await service.handleRoomJoined(
                room: room,
                occupancy: RoomOccupancy(nickname: "me", occupants: [], subject: nil),
                isNewlyCreated: false, accountID: accountID
            )
        }
        defer { operation.cancel(); Task { await release.signal() } }
        let arrived = try await boundedOutcome { await entered.wait() }
        try #require(arrived != nil)
        #expect(service.roomJoinNotifiers[RoomJoinKey(accountID: accountID, room: room)]?.id == notifierID)
        if cancel { operation.cancel() }
        await release.signal()
        await operation.value
        #expect(service.roomJoinNotifiers.isEmpty)
        #expect(await service.awaitRoomJoinedEcho(stream: stream, timeout: .seconds(1)) == !cancel)
    }

    @Test
    func `chat facade observes participant and invitation owner mutations`() async {
        let chat = ChatService(store: MockPersistenceStore(), transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
        let participantsChanged = Mutex(false)
        withObservationTracking {
            _ = chat.participants(forRoomJIDString: room.description, accountID: accountID)
        } onChange: {
            participantsChanged.withLock { $0 = true }
        }
        await chat.handleEvent(.roomOccupantJoined(room: room, occupant: RoomOccupant(nickname: "peer", affiliation: .member, role: .participant)), accountID: accountID)
        #expect(participantsChanged.withLock { $0 })
        #expect(chat.participantCount(forRoomJIDString: room.description, accountID: accountID) == 1)
        let invitesChanged = Mutex(false)
        withObservationTracking { _ = chat.pendingInvites } onChange: { invitesChanged.withLock { $0 = true } }
        await chat.handleEvent(.roomInviteReceived(RoomInvite(room: room, from: .bare(room), reason: nil, password: nil, isDirect: false)), accountID: accountID)
        #expect(invitesChanged.withLock { $0 })
        #expect(chat.pendingInvites.count == 1)
    }
}
