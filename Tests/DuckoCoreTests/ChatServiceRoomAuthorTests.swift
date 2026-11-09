import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let roomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let accountJID = BareJID.parse(testJIDString)!

/// A message of `type` that `nickname` sent through the room, stamped with the room's stanza-id `R-<id>`, and with
/// `occupantID` when given.
private func roomStanza(
    from nickname: String, id: String, body: String, occupantID: String?, type: XMPPMessage.MessageType = .groupchat, children: [DuckoXMPP.XMLElement] = []
) -> XMPPMessage {
    var message = XMPPMessage(type: type, to: .bare(accountJID), id: id)
    message.from = .full(FullJID(bareJID: roomJID, resourcePart: nickname)!)
    message.body = body
    if let occupantID {
        message.element.addChild(DuckoXMPP.XMLElement(name: "occupant-id", namespace: XMPPNamespaces.occupantID, attributes: ["id": occupantID]))
    }
    message.element.addChild(DuckoXMPP.XMLElement(
        name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "R-\(id)", "by": roomJID.description]
    ))
    for child in children {
        message.element.addChild(child)
    }
    return message
}

/// A chat service whose account has joined `roomJID` as `me` through a mock transport, with `bob` in the room. The
/// room's module answers who sent each stanza, as it does when it dispatches one.
@MainActor
private struct JoinedRoom {
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let transcripts: MockTranscriptStore
    let muc: MUCModule
    let room: Conversation
    let accountID: UUID

    /// Joins a room that advertises `features`, or whose features stay unknown when nil, gives the user's own presence
    /// `ownOccupantID`, and shows the real JIDs of its occupants when `revealsJIDs`.
    static func join(features: [String]?, ownOccupantID: String? = nil, revealsJIDs: Bool) async throws -> JoinedRoom {
        let store = MockPersistenceStore()
        let transcripts = MockTranscriptStore()
        let transport = MockTransport()
        if let features {
            await transport.answerDiscoInfo(of: roomJID.description, features: features)
        } else {
            await transport.refuseDiscoInfo(of: roomJID.description)
        }
        let accountService = makeAccountService(store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MUCModule()]))
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        let connectTask = Task { @MainActor in
            try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
        }
        await simulateNoTLSConnect(transport)
        let accountID = try await connectTask.value
        let room = Conversation(
            id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
            isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
        )
        try await store.upsertConversation(room)
        let muc = try #require(await accountService.client(for: accountID)?.module(ofType: MUCModule.self))
        try await muc.joinRoom(roomJID, nickname: "me")
        let joined = JoinedRoom(
            transport: transport, accountService: accountService, chatService: chatService, transcripts: transcripts, muc: muc, room: room,
            accountID: accountID
        )
        try await joined.occupantJoins("bob", realJID: revealsJIDs ? "bob@example.com/phone" : nil)
        let ownOccupant = ownOccupantID.map { "<occupant-id xmlns='urn:xmpp:occupant-id:0' id='\($0)'/>" } ?? ""
        let ownJID = revealsJIDs ? " jid='\(testJIDString)/ducko'" : ""
        await transport.simulateReceive(
            "<presence from='\(roomJID)/me'><x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<item affiliation='member' role='participant'\(ownJID)/><status code='110'/></x>\(ownOccupant)</presence>"
        )
        try await eventually { muc.confirmedNickname(in: roomJID) == "me" }
        return joined
    }

    /// Who sent `message`, as the room's module tells it when it dispatches the stanza.
    func author(of message: XMPPMessage) -> RoomAuthorIdentity? {
        muc.roomAuthor(of: message, in: roomJID)
    }

    func presenceSession(of nickname: String) -> String? {
        author(of: roomStanza(from: nickname, id: "probe", body: "", occupantID: nil))?.presenceSession
    }

    func occupantJoins(_ nickname: String, realJID: String?, show: String? = nil) async throws {
        let jid = realJID.map { " jid='\($0)'" } ?? ""
        let showElement = show.map { "<show>\($0)</show>" } ?? ""
        await transport.simulateReceive(
            "<presence from='\(roomJID)/\(nickname)'>\(showElement)<x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<item affiliation='member' role='participant'\(jid)/></x></presence>"
        )
        try await eventually { presenceSession(of: nickname) != nil }
    }

    func occupantLeaves(_ nickname: String) async throws {
        await transport.simulateReceive(
            "<presence from='\(roomJID)/\(nickname)' type='unavailable'><x xmlns='http://jabber.org/protocol/muc#user'>"
                + "<item affiliation='member' role='none'/></x></presence>"
        )
        try await eventually { presenceSession(of: nickname) == nil }
    }

    /// Updates `nickname`'s presence, and waits until the module has handled it.
    func presenceUpdates(_ nickname: String, realJID: String?) async throws {
        try await occupantJoins(nickname, realJID: realJID, show: "away")
        // A later occupant's arrival is handled after the update, so it shows the update was handled.
        try await occupantJoins("dave", realJID: nil)
    }

    /// Files `message` as the room's live message.
    func receive(_ message: XMPPMessage) async {
        await chatService.handleEvent(.roomMessageReceived(message, author: author(of: message)), accountID: accountID)
    }

    /// The user's own room message `m-own`, known by the room's stanza-id `R-m-own`.
    func addOwnMessage() async -> ChatMessage {
        let own = ChatMessage(
            id: UUID(), conversationID: room.id, stanzaID: "m-own", serverID: "R-m-own", fromJID: roomJID.description, body: "Mine",
            timestamp: Date(), isOutgoing: true, isDelivered: false, isEdited: false, type: "groupchat"
        )
        await transcripts.addMessage(own)
        return own
    }

    /// Delivers the amendment `stanza` carries, live, as the room's module reports it: a correction of `originalID` to
    /// `Fixed`, or a retraction of the message the room knows as `R-<originalID>` when `isRetraction`.
    func amend(_ originalID: String, isRetraction: Bool, with stanza: XMPPMessage) async throws {
        let from = try #require(stanza.from)
        let event: XMPPEvent = isRetraction
            ? .messageRetracted(originalID: "R-\(originalID)", from: from, messageType: .groupchat, roomAuthor: author(of: stanza))
            : .messageCorrected(originalID: originalID, newBody: "Fixed", replyFallbackRange: nil, from: from, messageType: .groupchat, roomAuthor: author(of: stanza))
        await chatService.handleEvent(event, accountID: accountID)
    }

    /// Whether the stored message the room knows by `stanzaID` took a correction or retraction.
    func isAmended(_ stanzaID: String, isRetraction: Bool) async throws -> Bool {
        let stored = try #require(await transcripts.messages.first { $0.stanzaID == stanzaID })
        let message = try #require(await transcripts.findMessage(id: stored.id, conversationID: room.id))
        return isRetraction ? message.isRetracted : message.body == "Fixed"
    }

    func disconnect() async {
        await accountService.disconnect(accountID: accountID)
    }
}

enum ChatServiceRoomAuthorTests {
    @MainActor
    struct OccupantIDRoom {
        enum Amendment: CaseIterable {
            case sameID, otherID, withoutID, originalWithoutID, otherNickname
        }

        /// The room shows bob's real JID, and his presence continues, so only the occupant id tells the author apart.
        @Test(arguments: Amendment.allCases, [false, true])
        func `Another occupant's amendment applies only with the original's nickname and occupant id`(
            amendment: Amendment, isRetraction: Bool
        ) async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.occupantID, XMPPNamespaces.stanzaID], revealsJIDs: true)
            await harness.receive(roomStanza(from: "bob", id: "m1", body: "helo", occupantID: amendment == .originalWithoutID ? nil : "occupant-bob"))
            let occupantID: String? = switch amendment {
            case .sameID, .originalWithoutID, .otherNickname: "occupant-bob"
            case .otherID: "occupant-eve"
            case .withoutID: nil
            }
            let sender = amendment == .otherNickname ? "carol" : "bob"

            try await harness.amend("m1", isRetraction: isRetraction, with: roomStanza(from: sender, id: "m2", body: "Fixed", occupantID: occupantID))

            #expect(try await harness.isAmended("m1", isRetraction: isRetraction) == (amendment == .sameID))
            await harness.disconnect()
        }

        enum OwnAmendment: CaseIterable {
            case ownID, otherID, withoutID
        }

        /// The room shows the account's real JID, and the echo comes from the user's current presence, so neither stands
        /// in for the user's occupant id.
        @Test(arguments: OwnAmendment.allCases, [false, true])
        func `The user's own room message takes amendments only with the user's occupant id`(amendment: OwnAmendment, isRetraction: Bool) async throws {
            let harness = try await JoinedRoom.join(
                features: [XMPPNamespaces.occupantID, XMPPNamespaces.stanzaID], ownOccupantID: "occupant-me", revealsJIDs: true
            )
            _ = await harness.addOwnMessage()
            let occupantID: String? = switch amendment {
            case .ownID: "occupant-me"
            case .otherID: "occupant-eve"
            case .withoutID: nil
            }
            let echo = roomStanza(from: "me", id: "m2", body: "Fixed", occupantID: occupantID)
            #expect(harness.author(of: echo)?.realJID == accountJID)

            try await harness.amend("m-own", isRetraction: isRetraction, with: echo)

            #expect(try await harness.isAmended("m-own", isRetraction: isRetraction) == (amendment == .ownID))
            await harness.disconnect()
        }
    }

    @MainActor
    struct OccupantIDRoomWithoutStanzaIDs {
        enum Delivery: CaseIterable {
            case room, privateMessage, privateCarbon
        }

        /// The room lists no stanza-ids, so its messages are stored without the room's id, and only the occupant id tells
        /// a repeated message apart from another occupant's that took bob's nickname and reused the message id.
        @Test(arguments: Delivery.allCases, [false, true])
        func `A repeated message id is a copy only under the same occupant id`(delivery: Delivery, isSameOccupant: Bool) async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.occupantID], revealsJIDs: false)
            func receive(_ message: XMPPMessage) async {
                let event: XMPPEvent = switch delivery {
                case .room: .roomMessageReceived(message, author: harness.author(of: message))
                case .privateMessage: .mucPrivateMessageReceived(message, author: harness.author(of: message))
                case .privateCarbon: .messageCarbonReceived(ForwardedMessage(message: message, timestamp: nil))
                }
                await harness.chatService.handleEvent(event, accountID: harness.accountID)
            }
            let type: XMPPMessage.MessageType = delivery == .room ? .groupchat : .chat
            let first = roomStanza(from: "bob", id: "m1", body: "first", occupantID: "occupant-bob", type: type)
            #expect(harness.author(of: first)?.roomSupportsOccupantIDs == true)
            await receive(first)

            await receive(roomStanza(from: "bob", id: "m1", body: "second", occupantID: isSameOccupant ? "occupant-bob" : "occupant-eve", type: type))

            #expect(await harness.transcripts.messages.map(\.body) == (isSameOccupant ? ["first"] : ["first", "second"]))
            await harness.disconnect()
        }
    }

    @MainActor
    struct RoomWithoutOccupantIDs {
        /// bob's presence ends between the two, so only his real JID ties them.
        @Test
        func `A real JID applies another occupant's correction, even after they rejoined`() async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.stanzaID], revealsJIDs: true)
            await harness.receive(roomStanza(from: "bob", id: "m1", body: "helo", occupantID: nil))
            try await harness.occupantLeaves("bob")
            try await harness.occupantJoins("bob", realJID: "bob@example.com/laptop")

            try await harness.amend("m1", isRetraction: false, with: roomStanza(from: "bob", id: "m2", body: "Fixed", occupantID: nil))

            #expect(try await harness.isAmended("m1", isRetraction: false))
            await harness.disconnect()
        }

        /// Without `muc_nonanonymous`, the room is semi-anonymous and shows real JIDs only to the user as a moderator.
        @Test(arguments: [false, true])
        func `A real JID applies another occupant's retraction only in a non-anonymous room`(isNonAnonymous: Bool) async throws {
            let harness = try await JoinedRoom.join(
                features: [XMPPNamespaces.stanzaID] + (isNonAnonymous ? [XMPPNamespaces.mucNonAnonymous] : []), revealsJIDs: true
            )
            await harness.receive(roomStanza(from: "bob", id: "m1", body: "helo", occupantID: nil))

            try await harness.amend("m1", isRetraction: true, with: roomStanza(from: "bob", id: "m2", body: "Fixed", occupantID: nil))

            #expect(try await harness.isAmended("m1", isRetraction: true) == isNonAnonymous)
            await harness.disconnect()
        }

        @Test(arguments: [false, true])
        func `The same presence applies another occupant's correction across a presence update, but not a retraction`(isRetraction: Bool) async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.stanzaID], revealsJIDs: false)
            await harness.receive(roomStanza(from: "bob", id: "m1", body: "helo", occupantID: nil))
            let session = harness.presenceSession(of: "bob")
            try await harness.presenceUpdates("bob", realJID: nil)
            #expect(harness.presenceSession(of: "bob") == session)

            try await harness.amend("m1", isRetraction: isRetraction, with: roomStanza(from: "bob", id: "m2", body: "Fixed", occupantID: nil))

            #expect(try await harness.isAmended("m1", isRetraction: isRetraction) == !isRetraction)
            await harness.disconnect()
        }

        @Test
        func `After a leave and rejoin, another occupant's correction is ignored`() async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.stanzaID], revealsJIDs: false)
            await harness.receive(roomStanza(from: "bob", id: "m1", body: "helo", occupantID: nil))
            try await harness.occupantLeaves("bob")
            try await harness.occupantJoins("bob", realJID: nil)

            try await harness.amend("m1", isRetraction: false, with: roomStanza(from: "bob", id: "m2", body: "Fixed", occupantID: nil))

            #expect(try await !harness.isAmended("m1", isRetraction: false))
            await harness.disconnect()
        }

        /// The room shows the account's real JID on the user's echo, which a retraction trusts only in a non-anonymous
        /// room.
        @Test(arguments: [false, true], [false, true])
        func `The account's real JID applies the user's own amendment, a retraction only in a non-anonymous room`(
            isNonAnonymous: Bool, isRetraction: Bool
        ) async throws {
            let harness = try await JoinedRoom.join(
                features: [XMPPNamespaces.stanzaID] + (isNonAnonymous ? [XMPPNamespaces.mucNonAnonymous] : []), revealsJIDs: true
            )
            _ = await harness.addOwnMessage()
            let echo = roomStanza(from: "me", id: "m2", body: "Fixed", occupantID: nil)
            #expect(harness.author(of: echo)?.realJID == accountJID)

            try await harness.amend("m-own", isRetraction: isRetraction, with: echo)

            #expect(try await harness.isAmended("m-own", isRetraction: isRetraction) == (!isRetraction || isNonAnonymous))
            await harness.disconnect()
        }

        /// In a semi-anonymous room, only the user's current presence ties the room's echo to the user.
        @Test(arguments: [false, true])
        func `The user's own live correction echo applies by presence, and a retraction echo does not`(isRetraction: Bool) async throws {
            let harness = try await JoinedRoom.join(features: [XMPPNamespaces.stanzaID], revealsJIDs: false)
            _ = await harness.addOwnMessage()

            try await harness.amend("m-own", isRetraction: isRetraction, with: roomStanza(from: "me", id: "m2", body: "Fixed", occupantID: nil))

            #expect(try await harness.isAmended("m-own", isRetraction: isRetraction) == !isRetraction)
            await harness.disconnect()
        }
    }

    @MainActor
    struct UnknownFeatures {
        /// Join history can hold another occupant's message from when they held the user's nickname. Only a live
        /// message under it is the user's while the room's features are unknown, since no one else holds it meanwhile.
        @Test(arguments: [false, true])
        func `A message under the user's confirmed nickname is theirs only when it is not delayed`(isDelayed: Bool) async throws {
            let harness = try await JoinedRoom.join(features: nil, revealsJIDs: false)
            var message = roomStanza(from: "me", id: "m1", body: "Not sent from here", occupantID: nil)
            if isDelayed {
                message.element.addChild(DuckoXMPP.XMLElement(
                    name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": roomJID.description, "stamp": "2026-02-28T10:00:00Z"]
                ))
            }
            let author = try #require(harness.author(of: message))
            #expect(author.roomSupportsOccupantIDs == nil)

            await harness.receive(message)

            #expect(await harness.transcripts.messages.map(\.isOutgoing) == (isDelayed ? [false] : []))
            await harness.disconnect()
        }

        /// The amendment matches the original on every other count, but the room's features were unknown when it came.
        /// The same amendment from a room known to lack occupant ids applies by the real JID.
        @Test(arguments: [nil, false] as [Bool?], [false, true])
        func `Another occupant's amendment is ignored while the room's features are unknown`(
            roomSupportsOccupantIDs: Bool?, isRetraction: Bool
        ) async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let accountID = UUID()
            let room = Conversation(
                id: UUID(), accountID: accountID, jid: roomJID, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
            )
            await store.addConversation(room)
            await transcripts.addMessage(ChatMessage(
                id: UUID(), conversationID: room.id, stanzaID: "m1", serverID: "R-m1", fromJID: "bob",
                roomSender: RoomSenderIdentity(realJID: "bob@example.com", presenceSession: "session-bob"), body: "helo",
                timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: "groupchat"
            ))
            let service = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            service.featureSource = FixedFeatureSource(roomFeatures: [XMPPNamespaces.mucNonAnonymous])
            let author = RoomAuthorIdentity(
                roomSupportsOccupantIDs: roomSupportsOccupantIDs, realJID: BareJID.parse("bob@example.com"), presenceSession: "session-bob"
            )
            let bob = try JID.full(#require(FullJID(bareJID: roomJID, resourcePart: "bob")))

            await service.handleEvent(
                isRetraction
                    ? .messageRetracted(originalID: "R-m1", from: bob, messageType: .groupchat, roomAuthor: author)
                    : .messageCorrected(originalID: "m1", newBody: "Fixed", replyFallbackRange: nil, from: bob, messageType: .groupchat, roomAuthor: author),
                accountID: accountID
            )

            #expect(await transcripts.amendments.isEmpty == (roomSupportsOccupantIDs == nil))
        }
    }
}
