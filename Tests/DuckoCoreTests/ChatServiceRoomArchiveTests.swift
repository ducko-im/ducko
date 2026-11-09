import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let omemoPayload = "<encrypted xmlns='urn:xmpp:omemo:2'><header sid='1'/><payload>AAAA</payload></encrypted>"

/// An account and rooms that archive and advertise occupant ids, where a room's features are no longer known once they
/// were asked for, as a rejoin of the room leaves them while it asks again.
@MainActor
private struct RejoiningFeatureSource: DiscoveredFeatureSource {
    let features = FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.occupantID])

    func accountInfo(accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await features.accountInfo(accountID: accountID)
    }

    func roomInfo(_ room: BareJID, accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await features.roomInfo(room, accountID: accountID)
    }

    func knownAccountInfo(accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        features.knownAccountInfo(accountID: accountID)
    }

    func knownRoomInfo(_ room: BareJID, accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        nil
    }
}

/// A room's archive is read only when it advertises `urn:xmpp:mam:2` and, where the room advertises occupant ids, once
/// the user's own is known. Each entry is known by the archive's id for it.
@MainActor
struct ChatServiceRoomArchiveTests {
    private func archiveQueries(on transport: MockTransport) async -> [String] {
        await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("urn:xmpp:mam:2") }
    }

    @Test
    func `History paging waits for the join while the user's own occupant id is unknown`() async throws {
        let harness = try await ArchiveHarness.connect(ownOccupantID: nil)

        let early = harness.fetchHistory()
        let error = await #expect(throws: ChatService.ChatServiceError.self) { try await early.value }
        guard case .archiveNotReady? = error else {
            Issue.record("Expected archiveNotReady, got \(String(describing: error))")
            return
        }
        #expect(await archiveQueries(on: harness.transport).isEmpty)

        let occupancy = RoomOccupancy(nickname: "alice", occupants: [], subject: nil, ownOccupantID: "occupant-alice")
        await harness.chatService.handleEvent(.roomJoined(room: roomJID, occupancy: occupancy, isNewlyCreated: false), accountID: harness.accountID)
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        try await harness.answerNextQuery(with: [.original("m1", serverID: "R1", body: "hello", at: "10:00:00")], complete: true, answered: &answered)

        #expect(try await fetch.value.messages.map(\.body) == ["hello"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    func `An archive that does not advertise mam:2 is not asked`(isRoom: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = FixedFeatureSource(
            accountFeatures: [XMPPNamespaces.stanzaID], roomFeatures: [XMPPNamespaces.stanzaID, XMPPNamespaces.occupantID]
        )
        let contactJID = try #require(BareJID.parse("bob@example.com"))

        let (messages, hasMore) = try await harness.chatService.fetchServerHistory(
            jid: isRoom ? roomJID : contactJID, accountID: harness.accountID, before: nil, limit: 50
        )

        #expect(messages.isEmpty)
        #expect(!hasMore)
        #expect(await archiveQueries(on: harness.transport).isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test
    func `Reading the same range twice adds nothing, though its entry carries no stanza-id`() async throws {
        let harness = try await ArchiveHarness.connect()
        var answered: Set<String> = []

        for _ in 0 ..< 2 {
            let fetch = harness.fetchHistory()
            try await harness.answerNextQuery(with: [RoomEntry(id: "m1", stamp: "10:00:00", body: "hello")], complete: true, answered: &answered)
            _ = try await fetch.value
        }

        let stored = try await harness.storedMessages()
        #expect(stored.map(\.serverID) == ["arch-m1"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    enum ArchivedSender: CaseIterable {
        case sameSender, sameNicknameStoredWithoutOccupantID, otherNickname, otherOccupantUnderTheNickname

        /// Whether the stored message is the entry's copy.
        var isSameMessage: Bool {
            switch self {
            case .sameSender, .sameNicknameStoredWithoutOccupantID: true
            case .otherNickname, .otherOccupantUnderTheNickname: false
            }
        }
    }

    /// A room's stanza-ids are not trusted while its features are unknown, so a live message can be stored without one.
    /// Someone who takes the sender's nickname can reuse the message's id, and only the occupant id tells them apart. A
    /// message stored without one is the same sender's under the nickname.
    @Test(arguments: ArchivedSender.allCases, [false, true])
    func `A room message stored without a server id gains the archive's id from the same sender's entry`(
        sender: ArchivedSender, isEncrypted: Bool
    ) async throws {
        let harness = try await ArchiveHarness.connect()
        let storedOccupantID = sender == .sameNicknameStoredWithoutOccupantID ? nil : "occupant-bob"
        await harness.addMessage("m1", serverID: nil, body: "hello", occupantID: storedOccupantID, isEncrypted: isEncrypted)
        var entry = RoomEntry.original("m1", serverID: "R1", body: "hello", at: "10:00:00")
        if isEncrypted {
            entry.payload = omemoPayload
        }
        switch sender {
        case .sameSender, .sameNicknameStoredWithoutOccupantID:
            break
        case .otherNickname:
            entry.nick = "carol"
            entry.occupantID = "occupant-carol"
        case .otherOccupantUnderTheNickname:
            entry.occupantID = "occupant-eve"
        }

        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        try await harness.answerNextQuery(with: [entry], complete: true, answered: &answered)
        _ = try await fetch.value

        let stored = try await harness.storedMessages()
        #expect(stored.count == (sender.isSameMessage ? 1 : 2))
        #expect(stored.filter { $0.serverID == nil }.map(\.roomSender?.occupantID) == (sender.isSameMessage ? [] : ["occupant-bob"]))
        let archived = try #require(await harness.transcripts.findMessage(serverID: "R1", conversationID: harness.room.id))
        #expect(archived.fromJID == entry.nick)
        #expect(archived.roomSender?.occupantID == (sender.isSameMessage ? storedOccupantID : entry.occupantID))
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    func `The user's own archived message and correction stay theirs when the room's features are cleared during the read`(
        isCatchUp: Bool
    ) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = RejoiningFeatureSource()
        let original = RoomEntry(nick: "alice", occupantID: "occupant-alice", id: "m1", stamp: "10:00:00", body: "hello")
        var correction = RoomEntry.correction("m2", of: "m1", body: "hello again", at: "10:01:00")
        correction.nick = "alice"
        correction.occupantID = "occupant-alice"

        var answered: Set<String> = []
        if isCatchUp {
            let catchUp = try await harness.startCatchUp(answered: &answered)
            try await harness.answerNextQuery(with: [original, correction], complete: true, answered: &answered)
            await catchUp.value
        } else {
            let fetch = harness.fetchHistory()
            try await harness.answerNextQuery(with: [original, correction], complete: true, answered: &answered)
            _ = try await fetch.value
        }

        let stored = try #require(try await harness.storedMessages().first)
        #expect(stored.isOutgoing)
        #expect(stored.roomSender?.occupantID == "occupant-alice")
        #expect(stored.body == "hello again")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test
    func `The user's own room message whose echo was missed gets the archive's id, not a second row`() async throws {
        let harness = try await ArchiveHarness.connect()
        let ownID = UUID()
        await harness.transcripts.addMessage(ChatMessage(
            id: ownID, conversationID: harness.room.id, stanzaID: "m1", fromJID: roomJID.description, body: "hello",
            timestamp: Date(timeIntervalSince1970: 1_772_272_800), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
        ))
        let echo = RoomEntry(nick: "alice", occupantID: "occupant-alice", id: "m1", stamp: "10:00:00", body: "hello")

        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        try await harness.answerNextQuery(with: [echo], complete: true, answered: &answered)
        _ = try await fetch.value

        #expect(try await harness.storedMessages().map(\.id) == [ownID])
        #expect(try await harness.transcripts.findMessage(serverID: "arch-m1", conversationID: harness.room.id)?.id == ownID)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
