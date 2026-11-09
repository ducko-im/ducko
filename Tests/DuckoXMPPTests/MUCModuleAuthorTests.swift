import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// A room module driven without a client, whose room answers disco#info with `features`, or with an error when they
/// are nil. Its events are recorded, and each id it generates is new.
private struct StubbedRoom {
    let module: MUCModule
    private let recorded: OSAllocatedUnfairLock<[XMPPEvent]>

    init(features: Set<String>?) {
        let recorded = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
        let counter = OSAllocatedUnfairLock(initialState: 0)
        self.recorded = recorded
        self.module = makeStubbedRoomModule(
            emitEvent: { event in recorded.withLock { $0.append(event) } },
            generateID: {
                counter.withLock { count in
                    count += 1
                    return "id-\(count)"
                }
            },
            answerRoomInfo: {
                guard let features else { throw XMPPStanzaError(errorType: .cancel, condition: .itemNotFound) }
                return discoInfoQuery(features: features)
            }
        )
    }

    var events: [XMPPEvent] {
        recorded.withLock { $0 }
    }

    func join(statusCodes: [Int] = [110], occupantID: String = "own-id") async throws {
        try await module.joinRoom(testRoomJID, nickname: "me")
        try receivePresence(from: "me", occupantID: occupantID, statusCodes: statusCodes)
    }

    func receivePresence(
        from nickname: String, jid: String? = nil, occupantID: String? = nil, type: String? = nil,
        statusCodes: [Int] = [], newNickname: String? = nil, show: String? = nil
    ) throws {
        let typeAttribute = type.map { " type='\($0)'" } ?? ""
        let jidAttribute = jid.map { " jid='\($0)'" } ?? ""
        let nickAttribute = newNickname.map { " nick='\($0)'" } ?? ""
        let statuses = statusCodes.map { "<status code='\($0)'/>" }.joined()
        let occupantIDElement = occupantID.map { "<occupant-id xmlns='\(XMPPNamespaces.occupantID)' id='\($0)'/>" } ?? ""
        let showElement = show.map { "<show>\($0)</show>" } ?? ""
        try module.handlePresence(XMPPPresence(element: stanza("""
        <presence from='\(testRoomJID)/\(nickname)'\(typeAttribute)>\(showElement)\
        <x xmlns='\(XMPPNamespaces.mucUser)'><item affiliation='member' role='participant'\(jidAttribute)\(nickAttribute)/>\(statuses)</x>\
        \(occupantIDElement)</presence>
        """)))
    }

    /// Who the module says sent a live message from `nickname` now.
    func liveAuthor(of nickname: String) throws -> RoomAuthorIdentity? {
        try module.roomAuthor(of: roomMessage(from: nickname), in: testRoomJID)
    }

    /// The author attached to the last room message the module reported.
    var lastRoomMessageAuthor: RoomAuthorIdentity? {
        events.compactMap { if case let .roomMessageReceived(_, author) = $0 { author } else { nil } }.last
    }
}

private func roomMessage(from nickname: String, occupantID: String? = nil, delayed: Bool = false) throws -> XMPPMessage {
    let occupantIDElement = occupantID.map { "<occupant-id xmlns='\(XMPPNamespaces.occupantID)' id='\($0)'/>" } ?? ""
    let delay = delayed ? "<delay xmlns='\(XMPPNamespaces.delay)' from='\(testRoomJID)' stamp='2026-01-01T00:00:00Z'/>" : ""
    return try XMPPMessage(element: stanza("""
    <message type='groupchat' from='\(testRoomJID)/\(nickname)' id='m-\(nickname)'><body>Hi</body>\(occupantIDElement)\(delay)</message>
    """))
}

// MARK: - Tests

enum MUCModuleAuthorTests {
    struct OwnOccupantID {
        @Test
        func `The self-presence's occupant id is kept before the room's features are known`() async throws {
            let room = StubbedRoom(features: nil)

            try await room.join(statusCodes: [110, 201], occupantID: "own-id")

            #expect(room.module.knownRoomInfo(for: testRoomJID) == nil)
            #expect(room.module.ownOccupantID(in: testRoomJID) == "own-id")
            let occupancy = room.events.compactMap { if case let .roomJoined(_, occupancy, _) = $0 { occupancy } else { nil } }.last
            #expect(occupancy?.ownOccupantID == "own-id")
        }
    }

    struct Snapshot {
        @Test(arguments: [(true, "alice-id"), (false, nil)] as [(Bool, String?)])
        func `A message's occupant id is carried only when the room advertises occupant ids`(advertised: Bool, expected: String?) async throws {
            let room = StubbedRoom(features: advertised ? [XMPPNamespaces.occupantID] : [])
            try await room.join()

            try room.module.handleMessage(roomMessage(from: "alice", occupantID: "alice-id"))

            let author = try #require(room.lastRoomMessageAuthor)
            #expect(author.roomSupportsOccupantIDs == advertised)
            #expect(author.occupantID == expected)
        }

        @Test
        func `A message taken while the room's features are unknown carries no occupant id`() async throws {
            let room = StubbedRoom(features: nil)
            try await room.join()

            try room.module.handleMessage(roomMessage(from: "alice", occupantID: "alice-id"))

            let author = try #require(room.lastRoomMessageAuthor)
            #expect(author.roomSupportsOccupantIDs == nil)
            #expect(author.occupantID == nil)
        }

        /// Join history replays what the nickname's earlier holder sent, so whoever holds it now says nothing about it.
        @Test
        func `Join history carries its own occupant id and not the identity of the nickname's current holder`() async throws {
            let room = StubbedRoom(features: [XMPPNamespaces.occupantID])
            try await room.join()
            try room.receivePresence(from: "bob", jid: "carol@example.com/phone", occupantID: "carol-id")

            try room.module.handleMessage(roomMessage(from: "bob", occupantID: "bob-id", delayed: true))

            let history = try #require(room.lastRoomMessageAuthor)
            #expect(history.occupantID == "bob-id")
            #expect(history.realJID == nil)
            #expect(history.presenceSession == nil)
            let live = try #require(try room.liveAuthor(of: "bob"))
            #expect(live.realJID == BareJID.parse("carol@example.com"))
            #expect(live.presenceSession != nil)
        }

        @Test
        func `A room private chat's correction carries who sent it`() async throws {
            let room = StubbedRoom(features: [XMPPNamespaces.occupantID])
            try await room.join()
            try room.receivePresence(from: "alice", jid: "alice@example.com/phone", occupantID: "alice-id")
            let recorded = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
            let chatModule = ChatModule(mucModule: room.module)
            chatModule.setUp(makeStubModuleContext(emitEvent: { event in recorded.withLock { $0.append(event) } }))

            try chatModule.handleMessage(XMPPMessage(element: stanza("""
            <message type='chat' from='\(testRoomJID)/alice' id='pm-2'><body>Fixed</body>\
            <replace xmlns='\(XMPPNamespaces.messageCorrect)' id='pm-1'/>\
            <occupant-id xmlns='\(XMPPNamespaces.occupantID)' id='alice-id'/></message>
            """)))

            let author = recorded.withLock { $0 }.compactMap { event -> RoomAuthorIdentity? in
                if case let .messageCorrected(_, _, _, _, _, roomAuthor) = event { roomAuthor } else { nil }
            }.first
            #expect(author?.occupantID == "alice-id")
            #expect(author?.realJID == BareJID.parse("alice@example.com"))
        }
    }

    struct PresenceSessions {
        @Test
        func `A presence update keeps an occupant's session`() async throws {
            let room = StubbedRoom(features: [])
            try await room.join()
            try room.receivePresence(from: "bob")
            let session = try #require(try room.liveAuthor(of: "bob")?.presenceSession)

            try room.receivePresence(from: "bob", show: "away")

            #expect(try room.liveAuthor(of: "bob")?.presenceSession == session)
        }

        @Test
        func `A leave ends an occupant's session, and a return starts another`() async throws {
            let room = StubbedRoom(features: [])
            try await room.join()
            try room.receivePresence(from: "bob")
            let session = try #require(try room.liveAuthor(of: "bob")?.presenceSession)

            try room.receivePresence(from: "bob", type: "unavailable")
            #expect(try room.liveAuthor(of: "bob")?.presenceSession == nil)

            try room.receivePresence(from: "bob")
            let returned = try #require(try room.liveAuthor(of: "bob")?.presenceSession)
            #expect(returned != session)
        }

        @Test
        func `A nickname change gives the new nickname a fresh session`() async throws {
            let room = StubbedRoom(features: [])
            try await room.join()
            try room.receivePresence(from: "bob")
            let session = try #require(try room.liveAuthor(of: "bob")?.presenceSession)

            try room.receivePresence(from: "bob", type: "unavailable", statusCodes: [303], newNickname: "robert")
            try room.receivePresence(from: "robert")

            #expect(try room.liveAuthor(of: "bob")?.presenceSession == nil)
            let renamed = try #require(try room.liveAuthor(of: "robert")?.presenceSession)
            #expect(renamed != session)
        }

        @Test
        func `The user's own session is the one on the confirmed nickname's messages`() async throws {
            let room = StubbedRoom(features: [])
            try await room.module.joinRoom(testRoomJID, nickname: "me")
            #expect(room.module.ownPresenceSession(in: testRoomJID) == nil)

            try room.receivePresence(from: "me", statusCodes: [110])

            let session = try #require(room.module.ownPresenceSession(in: testRoomJID))
            #expect(try room.liveAuthor(of: "me")?.presenceSession == session)
        }
    }
}
