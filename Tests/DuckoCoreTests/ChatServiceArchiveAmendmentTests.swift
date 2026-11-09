import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

struct ChatServiceArchiveAmendmentTests {
    @Test(arguments: [false, true])
    @MainActor
    func `A correction on the page of its message applies in either order`(correctionFirst: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let original = RoomEntry.original("m1", serverID: "R1", body: "helo", at: "10:00:00")
        let correction = RoomEntry.correction("m2", of: "m1", body: "hello", at: "10:01:00")

        try await harness.answerNextQuery(with: correctionFirst ? [correction, original] : [original, correction], complete: true, answered: &answered)

        let (messages, _) = try await fetch.value
        #expect(messages.map(\.body) == ["hello"])
        let stored = try await harness.storedMessages()
        #expect(stored.map(\.body) == ["hello"])
        #expect(stored.first?.isEdited == true)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test
    @MainActor
    func `A correction on the newest page is applied once the pages back reach its message`() async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.correction("m9", of: "m1", body: "hello", at: "10:09:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.original("m5", serverID: "R5", body: "between", at: "10:05:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "helo", at: "10:00:00")], complete: false, answered: &answered
        )

        let (messages, hasMore) = try await fetch.value
        #expect(messages.map(\.body) == ["hello", "between"])
        #expect(hasMore)
        #expect(answered.count == 3)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Of the corrections of one message the newest text stays`(liveCorrectionFirst: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        await harness.addMessage("m1", serverID: "R1", body: "helo")
        if liveCorrectionFirst {
            let bob = try JID.full(#require(FullJID(bareJID: roomJID, resourcePart: "bob")))
            let author = RoomAuthorIdentity(roomSupportsOccupantIDs: true, occupantID: "occupant-bob")
            await harness.chatService.handleEvent(
                .messageCorrected(originalID: "m1", newBody: "hello at last", replyFallbackRange: nil, from: bob, messageType: .groupchat, roomAuthor: author),
                accountID: harness.accountID
            )
        }
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.correction("m3", of: "m1", body: "hello again", at: "10:02:00")], complete: false, answered: &answered
        )
        try await harness.answerNextQuery(
            with: [.correction("m2", of: "m1", body: "hello", at: "10:01:00")], complete: true, answered: &answered
        )

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.body) == [liveCorrectionFirst ? "hello at last" : "hello again"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// A retraction names its message by the archive's id for it, which an entry the archive stamped no stanza-id on
    /// has too.
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `An archived retraction removes its message and is never shown`(byModerator: Bool, originalCarriesStanzaID: Bool) async throws {
        let original = RoomEntry(id: "m1", serverID: originalCarriesStanzaID ? "R1" : nil, stamp: "10:00:00", body: "oops")
        let retraction = byModerator
            ? RoomEntry(
                nick: nil, id: "m2", stamp: "10:01:00", body: "A moderator removed a message",
                payload: "<retract xmlns='urn:xmpp:message-retract:1' id='\(original.archiveID)'>"
                    + "<moderated xmlns='urn:xmpp:message-moderate:1' by='\(roomJID)/mod'/></retract>"
            )
            : RoomEntry(
                id: "m2", stamp: "10:01:00", body: "bob retracted a message",
                payload: "<retract xmlns='urn:xmpp:message-retract:1' id='\(original.archiveID)'/>"
            )
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(with: [original, retraction], complete: true, answered: &answered)

        _ = try await fetch.value
        let stored = try await harness.storedMessages()
        #expect(stored.count == 1)
        #expect(stored.first?.isRetracted == true)
        #expect(stored.first?.body == "")
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Only the room itself moderates (XEP-0425), so an occupant's claim to have moderated bob's message changes nothing.
    @Test
    @MainActor
    func `An archived moderation from an occupant leaves the message`() async throws {
        let moderation = RoomEntry(
            nick: "eve", id: "m2", stamp: "10:01:00", body: "A moderator removed a message",
            payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'><moderated xmlns='urn:xmpp:message-moderate:1' by='\(roomJID)/eve'/></retract>"
        )
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []

        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "keep", at: "10:00:00"), moderation], complete: true, answered: &answered
        )

        _ = try await fetch.value
        let stored = try await harness.storedMessages()
        #expect(stored.map(\.body) == ["keep"])
        #expect(stored.first?.isRetracted == false)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The room's archive shows the sender's real JID (XEP-0313), and an occupant id counts only from a room that
    /// advertises them.
    @Test(arguments: [false, true])
    @MainActor
    func `An archived room message keeps who sent it`(roomAdvertisesOccupantIDs: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = FixedFeatureSource.archiving(roomFeatures: roomAdvertisesOccupantIDs ? [XMPPNamespaces.occupantID] : [])
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let original = RoomEntry(
            id: "m1", serverID: "R1", stamp: "10:00:00", body: "hello",
            payload: "<x xmlns='http://jabber.org/protocol/muc#user'><item jid='bob@example.com/phone'/></x>"
        )

        try await harness.answerNextQuery(with: [original], complete: true, answered: &answered)

        _ = try await fetch.value
        let stored = try await harness.storedMessages()
        #expect(stored.map(\.roomSender) == [RoomSenderIdentity(occupantID: roomAdvertisesOccupantIDs ? "occupant-bob" : nil, realJID: "bob@example.com")])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The room advertises occupant ids, so another occupant can post under the user's nickname while the user is away,
    /// and only the user's own occupant id makes an entry theirs.
    @Test(arguments: [false, true])
    @MainActor
    func `An archived room message under the user's nickname is theirs only with their occupant id`(hasOwnOccupantID: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let entry = RoomEntry(
            nick: "alice", occupantID: hasOwnOccupantID ? "occupant-alice" : "occupant-eve", id: "m1", serverID: "R1", stamp: "10:00:00", body: "hello"
        )

        try await harness.answerNextQuery(with: [entry], complete: true, answered: &answered)

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.isOutgoing) == [hasOwnOccupantID])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Without occupant ids, the real JID the room's archive shows tells the user's entries apart, and without one the
    /// user's nickname does.
    @Test(arguments: zip([nil, "alice@example.com/phone", "eve@example.com/phone"], [true, true, false]))
    @MainActor
    func `In a room without occupant ids, an archived message is the user's by real JID, else by nickname`(realJID: String?, isOwn: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = FixedFeatureSource.archiving()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        var entry = RoomEntry(nick: "alice", id: "m1", serverID: "R1", stamp: "10:00:00", body: "hello")
        entry.payload = realJID.map { "<x xmlns='http://jabber.org/protocol/muc#user'><item jid='\($0)'/></x>" } ?? ""

        try await harness.answerNextQuery(with: [entry], complete: true, answered: &answered)

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.isOutgoing) == [isOwn])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The room advertises occupant ids, so the archive's occupant id alone tells the author apart.
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `An archived amendment applies only with the original's occupant id`(isSameOccupant: Bool, isRetraction: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        var amendment = isRetraction
            ? RoomEntry(id: "m2", stamp: "10:01:00", body: "bob retracted a message", payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'/>")
            : RoomEntry.correction("m2", of: "m1", body: "hello", at: "10:01:00")
        amendment.occupantID = isSameOccupant ? "occupant-bob" : "occupant-eve"

        try await harness.answerNextQuery(
            with: [.original("m1", serverID: "R1", body: "helo", at: "10:00:00"), amendment], complete: true, answered: &answered
        )

        _ = try await fetch.value
        let stored = try #require(try await harness.storedMessages().first)
        #expect((isRetraction ? stored.isRetracted : stored.body == "hello") == isSameOccupant)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Without occupant ids, and with no presence to follow in an archive, only a real JID ties a correction to its
    /// message.
    @Test(arguments: [false, true])
    @MainActor
    func `In a room without occupant ids, an archived correction applies only with the same real JID`(showsRealJIDs: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = FixedFeatureSource.archiving()
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let realJID = showsRealJIDs ? "<x xmlns='http://jabber.org/protocol/muc#user'><item jid='bob@example.com/phone'/></x>" : ""
        var original = RoomEntry.original("m1", serverID: "R1", body: "helo", at: "10:00:00")
        original.payload = realJID
        var correction = RoomEntry.correction("m2", of: "m1", body: "hello", at: "10:01:00")
        correction.payload += realJID

        try await harness.answerNextQuery(with: [original, correction], complete: true, answered: &answered)

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.body) == [showsRealJIDs ? "hello" : "helo"])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Without occupant ids, a real JID ties an archived retraction to its message only where the room shows every
    /// occupant's real JID.
    @Test(arguments: [false, true])
    @MainActor
    func `In a room without occupant ids, an archived retraction applies by real JID only in a non-anonymous room`(isNonAnonymous: Bool) async throws {
        let harness = try await ArchiveHarness.connect()
        harness.chatService.featureSource = FixedFeatureSource.archiving(roomFeatures: isNonAnonymous ? [XMPPNamespaces.mucNonAnonymous] : [])
        let fetch = harness.fetchHistory()
        var answered: Set<String> = []
        let realJID = "<x xmlns='http://jabber.org/protocol/muc#user'><item jid='bob@example.com/phone'/></x>"
        var original = RoomEntry.original("m1", serverID: "R1", body: "helo", at: "10:00:00")
        original.payload = realJID
        let retraction = RoomEntry(
            id: "m2", stamp: "10:01:00", body: "bob retracted a message", payload: "<retract xmlns='urn:xmpp:message-retract:1' id='R1'/>" + realJID
        )

        try await harness.answerNextQuery(with: [original, retraction], complete: true, answered: &answered)

        _ = try await fetch.value
        #expect(try await harness.storedMessages().map(\.isRetracted) == [isNonAnonymous])
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
