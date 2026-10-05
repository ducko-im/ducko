import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let otherRoom = BareJID(localPart: "other", domainPart: "conference.example.com")!
private let rememberedRoom = BareJID(localPart: "remembered", domainPart: "conference.example.com")!

@MainActor
struct RoomResumptionTests {
    @Test
    func `A resumed stream shows the rooms' participants and flags again`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()

        try await fixture.drop(fixture.transports[0])
        #expect(fixture.participants(in: room).isEmpty)
        try await fixture.resume(on: fixture.transports[1])

        try await eventually { fixture.participants(in: room) == ["alice", "bob"] }
        #expect(fixture.chat.roomFlags(forRoomJIDString: room.description, accountID: fixture.accountID) == [.nonAnonymous])
        await fixture.close()
    }

    @Test
    func `A room message replayed ahead of the resume is stored`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])

        try await fixture.resume(on: fixture.transports[1], replaying: groupMessage(from: "bob", body: "Sent during the drop")) {
            try await eventually { try await fixture.storedBodies(in: room).contains("Sent during the drop") }
        }

        await fixture.close()
    }

    @Test
    func `An occupant who left during the drop is gone after the resume`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])

        try await fixture.resume(on: fixture.transports[1], replaying: occupantPresence("bob", type: "unavailable"))

        try await eventually { fixture.participants(in: room) == ["alice"] }
        await fixture.close()
    }

    @Test
    func `The replayed echo of an own message is not stored a second time`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.chat.sendGroupMessage(to: room, body: "Hello", accountID: fixture.accountID)
        let sent = try await sentStanza(on: fixture.transports[0], containing: "<body>Hello</body>")
        let stanzaID = try #require(extractIQID(from: sent))
        try await fixture.drop(fixture.transports[0])

        // While the resume is parked the account is not connected, so only the stanza id tells the echo apart.
        let replay = groupMessage(from: "alice", body: "Hello", id: stanzaID) + groupMessage(from: "bob", body: "After the echo")
        try await fixture.resume(on: fixture.transports[1], replaying: replay) {
            try await eventually { try await fixture.storedBodies(in: room).contains("After the echo") }
        }

        #expect(try await fixture.storedBodies(in: room).count { $0 == "Hello" } == 1)
        await fixture.close()
    }

    @Test
    func `A resume neither joins a carried room again nor fetches the bookmarks`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])

        try await fixture.resume(on: fixture.transports[1])
        try await eventually { fixture.bookmarks == [room.description] }
        // Sent after everything the resume itself put on the wire.
        try await fixture.chat.sendGroupMessage(to: room, body: "After the resume", accountID: fixture.accountID)
        _ = try await sentStanza(on: fixture.transports[1], containing: "After the resume")

        let sent = await fixture.transports[1].sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<presence") && $0.contains("to=\"\(room)") })
        #expect(!sent.contains { $0.contains(XMPPNamespaces.bookmarks2) })
        await fixture.close()
    }

    @Test
    func `A bookmark pushed during the drop is listed after the resume next to the kept ones`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        try await eventually { fixture.bookmarks.isEmpty }

        let push = bookmarksEvent("<item id='\(otherRoom)'><conference xmlns='urn:xmpp:bookmarks:1'/></item>")
        try await fixture.resume(on: fixture.transports[1], replaying: push)

        try await eventually { fixture.bookmarks.sorted() == [otherRoom.description, room.description] }
        await fixture.close()
    }

    @Test(arguments: [false, true])
    func `A room left during the drop is left once the stream resumes`(byRetraction: Bool) async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.connectFresh(on: fixture.transports[0], remembering: room)
        try await answerBookmarksFetch(on: fixture.transports[0], autoJoin: [room])
        try await fixture.completeJoin(of: room, on: fixture.transports[0])
        try await fixture.awaitSignInPass()
        try await fixture.drop(fixture.transports[0])
        if !byRetraction {
            await #expect(throws: ChatService.ChatServiceError.self) {
                try await fixture.chat.leaveRoom(jid: room, accountID: fixture.accountID)
            }
        }

        try await fixture.resume(on: fixture.transports[1], replaying: byRetraction ? bookmarksEvent("<retract id='\(room)'/>") : "") {
            // A leave stops the room from being remembered just before it finds the account without a connection.
            try await eventually { try await !fixture.isRemembered(room) }
        }

        let leave = try await sentStanza(on: fixture.transports[1], containing: "to=\"\(room)/alice\"")
        #expect(leave.hasPrefix("<presence") && leave.contains("type=\"unavailable\""))
        try await eventually { fixture.participants(in: room).isEmpty }
        await fixture.close()
    }

    @Test
    func `A leave requested during a drop is forgotten when a fresh session follows`() async throws {
        let fixture = RoomResumptionFixture(transports: [MockTransport(), MockTransport(), MockTransport()])
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        await #expect(throws: ChatService.ChatServiceError.self) {
            try await fixture.chat.leaveRoom(jid: room, accountID: fixture.accountID)
        }
        try await fixture.reconnectFresh(on: fixture.transports[1])
        try await answerBookmarksFetch(on: fixture.transports[1], autoJoin: [room])
        try await fixture.completeJoin(of: room, on: fixture.transports[1])
        try await fixture.awaitSignInPass()
        try await fixture.drop(fixture.transports[1])

        try await fixture.resume(on: fixture.transports[2])
        try await eventually { fixture.participants(in: room) == ["alice", "bob"] }
        // A leave the resume completed would be among these tasks.
        for task in fixture.chat.takePendingTasks() {
            await task.value
        }

        let sent = await fixture.transports[2].sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.contains("type=\"unavailable\"") })
        await fixture.close()
    }

    @Test
    func `A rejected resume joins each room once and shows nobody from before the drop`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn(remembering: otherRoom)
        try await fixture.drop(fixture.transports[0])

        try await fixture.reconnectFresh(on: fixture.transports[1])
        try await answerBookmarksFetch(on: fixture.transports[1], autoJoin: [room])
        try await fixture.awaitSignInPass()

        #expect(fixture.bookmarks == [room.description])
        let presences = await fixture.transports[1].sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("<presence") }
        #expect(presences.count { $0.contains("to=\"\(room)/alice\"") } == 1)
        #expect(presences.count { $0.contains("to=\"\(otherRoom)/alice\"") } == 1)
        #expect(fixture.participants(in: room).isEmpty)
        #expect(fixture.participants(in: otherRoom).isEmpty)
        await fixture.close()
    }

    @Test
    func `A resume after a failed reconnect attempt still restores the participants`() async throws {
        let failing = MockTransport(connectError: RoomResumptionFixture.ConnectFailure())
        let fixture = RoomResumptionFixture(transports: [MockTransport(), failing, MockTransport()])
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        await #expect(throws: RoomResumptionFixture.ConnectFailure.self) {
            try await fixture.environment.accountService.connect(accountID: fixture.accountID, password: "secret")
        }

        try await fixture.resume(on: fixture.transports[2])

        try await eventually { fixture.participants(in: room) == ["alice", "bob"] }
        await fixture.close()
    }

    @Test
    func `A sign-in pass the drop interrupted is finished on the resumed stream`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.connectFresh(on: fixture.transports[0], remembering: rememberedRoom)
        // The pass is waiting for its bookmarks when two rooms are joined and the connection drops.
        _ = try await sentStanza(on: fixture.transports[0], containing: XMPPNamespaces.bookmarks2)
        for joined in [room, rememberedRoom] {
            try await fixture.chat.joinRoom(jid: joined, nickname: "alice", accountID: fixture.accountID)
            try await fixture.completeJoin(of: joined, on: fixture.transports[0])
        }
        try await fixture.drop(fixture.transports[0])

        try await fixture.resume(on: fixture.transports[1])
        try await answerBookmarksFetch(on: fixture.transports[1], autoJoin: [room, otherRoom])
        try await fixture.awaitSignInPass()

        let presences = await fixture.transports[1].sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("<presence") }
        #expect(presences.count { $0.contains("to=\"\(otherRoom)/alice\"") } == 1)
        // Neither the carried room with a bookmark nor the carried one that is only remembered is joined again.
        #expect(!presences.contains { $0.contains("to=\"\(room)") || $0.contains("to=\"\(rememberedRoom)") })
        await fixture.close()
    }

    @Test
    func `A resumed sign-in pass whose fetch fails joins the auto-join rooms of the kept bookmarks`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.connectFresh(on: fixture.transports[0])
        _ = try await sentStanza(on: fixture.transports[0], containing: XMPPNamespaces.bookmarks2)
        // With auto-join off, the pushed bookmark is kept without its room being joined.
        fixture.environment.bookmarksService.autoJoinEnabled = false
        await fixture.transports[0].simulateReceive(bookmarksEvent("<item id='\(otherRoom)'><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>"))
        try await eventually { fixture.bookmarks == [otherRoom.description] }
        try await fixture.drop(fixture.transports[0])
        fixture.environment.bookmarksService.autoJoinEnabled = true

        try await fixture.resume(on: fixture.transports[1])
        try await fixture.failBookmarksFetch(on: fixture.transports[1])
        try await fixture.awaitSignInPass()

        let presences = await fixture.transports[1].sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("<presence") }
        #expect(presences.count { $0.contains("to=\"\(otherRoom)/alice\"") } == 1)
        await fixture.close()
    }

    @Test
    func `A sign-in pass that ends while its client tears down is not counted as complete`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.connectFresh(on: fixture.transports[0])
        _ = try await sentStanza(on: fixture.transports[0], containing: XMPPNamespaces.bookmarks2)
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.transports[0].installDisconnectGate(entered: entered, release: release)
        await fixture.transports[0].simulateDisconnect()
        // The client is tearing down, and the account still counts as connected until it has finished.
        try #require(try await boundedOutcome { await entered.wait() } != nil)

        // A pass that runs now has everything it sends refused, and reaches its end before the account catches up.
        let boundJID = try #require(FullJID.parse("\(testJIDString)/ducko"))
        await fixture.environment.bookmarksService.handleEvent(.streamResumed(boundJID), accountID: fixture.accountID)

        #expect(!fixture.environment.bookmarksService.completedSignInPass.contains(fixture.accountID))
        await release.signal()
        try await fixture.awaitDropped()
        await fixture.close()
    }

    @Test
    func `A bookmark pushed with auto-join has its room joined`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()

        await fixture.transports[0].simulateReceive(bookmarksEvent("<item id='\(otherRoom)'><conference xmlns='urn:xmpp:bookmarks:1' autojoin='true'/></item>"))

        let join = try await sentStanza(on: fixture.transports[0], containing: "to=\"\(otherRoom)/alice\"")
        #expect(join.hasPrefix("<presence"))
        await fixture.close()
    }

    @Test
    func `A sign-in pass interrupted on a later fresh session is finished on its resumed stream too`() async throws {
        let fixture = RoomResumptionFixture(transports: [MockTransport(), MockTransport(), MockTransport()])
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        try await fixture.reconnectFresh(on: fixture.transports[1])
        _ = try await sentStanza(on: fixture.transports[1], containing: XMPPNamespaces.bookmarks2)
        try await fixture.drop(fixture.transports[1])

        try await fixture.resume(on: fixture.transports[2])

        _ = try await sentStanza(on: fixture.transports[2], containing: XMPPNamespaces.bookmarks2)
        await fixture.close()
    }

    @Test
    func `A room the account was removed from during the drop shows nobody after the resume`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])

        let replay = occupantPresence("carol") + occupantPresence("alice", type: "unavailable", statusCodes: [110, 307])
        try await fixture.resume(on: fixture.transports[1], replaying: replay) {
            // The replayed join is shown until the resume is handled.
            try await eventually { fixture.participants(in: room) == ["carol"] }
        }

        try await eventually { fixture.participants(in: room).isEmpty }
        await fixture.close()
    }

    @Test
    func `A leave completed on a resume is not repeated on the next one`() async throws {
        let fixture = RoomResumptionFixture(transports: [MockTransport(), MockTransport(), MockTransport()])
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        await #expect(throws: ChatService.ChatServiceError.self) {
            try await fixture.chat.leaveRoom(jid: room, accountID: fixture.accountID)
        }
        try await fixture.resume(on: fixture.transports[1])
        _ = try await sentStanza(on: fixture.transports[1], containing: "type=\"unavailable\"")
        await fixture.transports[1].clearSentBytes()
        try await fixture.chat.joinRoom(jid: room, nickname: "alice", accountID: fixture.accountID)
        try await fixture.completeJoin(of: room, on: fixture.transports[1])
        try await fixture.drop(fixture.transports[1])

        try await fixture.resume(on: fixture.transports[2])
        try await eventually { fixture.participants(in: room) == ["alice", "bob"] }
        // A leave the resume completed would be among these tasks.
        for task in fixture.chat.takePendingTasks() {
            await task.value
        }

        let sent = await fixture.transports[2].sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.contains("type=\"unavailable\"") })
        await fixture.close()
    }

    @Test
    func `A leave the client refuses while it tears down is completed once the stream resumes`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await fixture.transports[0].installDisconnectGate(entered: entered, release: release)
        await fixture.transports[0].simulateDisconnect()
        // The client is tearing down, and the account still counts as connected until it has finished.
        try #require(try await boundedOutcome { await entered.wait() } != nil)

        await #expect(throws: XMPPClientError.self) {
            try await fixture.chat.leaveRoom(jid: room, accountID: fixture.accountID)
        }
        await release.signal()
        try await fixture.awaitDropped()
        try await fixture.resume(on: fixture.transports[1])

        let leave = try await sentStanza(on: fixture.transports[1], containing: "to=\"\(room)/alice\"")
        #expect(leave.hasPrefix("<presence") && leave.contains("type=\"unavailable\""))
        await fixture.close()
    }

    @Test
    func `The production factory seeds the room module with the rooms carried for a resume`() async throws {
        let fixture = RoomResumptionFixture()
        try await fixture.signIn()
        try await fixture.drop(fixture.transports[0])
        try await fixture.resume(on: fixture.transports[1])
        let carried = try #require(await fixture.carried)
        let account = try #require(fixture.environment.accountService.accounts.first)

        let (client, _) = await DefaultXMPPClientFactory().makeClient(account: account, password: "secret", resuming: carried, requireTLSOverride: nil, omemoService: nil)

        let occupancy = try #require(await client.module(ofType: MUCModule.self)?.roomOccupancies[room])
        #expect(Set(occupancy.occupants.map(\.nickname)) == ["alice", "bob"])
        await fixture.close()
    }
}

// MARK: - Stanzas

private func occupantPresence(_ nickname: String, in room: BareJID = room, type: String? = nil, statusCodes: [Int] = []) -> String {
    let typeAttribute = type.map { " type='\($0)'" } ?? ""
    let statuses = statusCodes.map { "<status code='\($0)'/>" }.joined()
    return """
    <presence from='\(room)/\(nickname)'\(typeAttribute)>\
    <x xmlns='http://jabber.org/protocol/muc#user'>\
    <item affiliation='member' role='participant'/>\(statuses)\
    </x>\
    </presence>
    """
}

private func groupMessage(from nickname: String, body: String, id: String? = nil) -> String {
    let idAttribute = id.map { " id='\($0)'" } ?? ""
    return "<message type='groupchat' from='\(room)/\(nickname)'\(idAttribute)><body>\(body)</body></message>"
}

/// A notification from the account's own bookmarks node carrying `items`.
private func bookmarksEvent(_ items: String) -> String {
    """
    <message from='\(testJIDString)'>\
    <event xmlns='http://jabber.org/protocol/pubsub#event'><items node='urn:xmpp:bookmarks:1'>\(items)</items></event>\
    </message>
    """
}

// MARK: - Fixture

/// A real `AppEnvironment` whose account drops and reconnects over one `MockTransport` per connection attempt.
@MainActor
private final class RoomResumptionFixture {
    struct ConnectFailure: Error {}

    let transports: [MockTransport]
    let environment: AppEnvironment
    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    private let resumeGate = ResumeGate()
    private let factory: RoomResumeFactory
    private(set) var accountID = UUID()
    private var sessions = 0

    var chat: ChatService {
        environment.chatService
    }

    var bookmarks: [String] {
        environment.bookmarksService.bookmarks.map(\.jidString)
    }

    init(transports: [MockTransport] = [MockTransport(), MockTransport()]) {
        self.transports = transports
        self.factory = RoomResumeFactory(transports: transports, gate: resumeGate)
        self.environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: MockCredentialStore(), clientFactory: factory)
    }

    func participants(in room: BareJID) -> [String] {
        chat.participants(forRoomJIDString: room.description, accountID: accountID).map(\.nickname).sorted()
    }

    func storedBodies(in room: BareJID) async throws -> [String] {
        let conversation = try await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)
        guard let conversation else { return [] }
        return try await transcripts.fetchMessages(for: conversation.id, before: nil, limit: 50).map(\.body)
    }

    // MARK: Sessions

    /// Signs in on the first transport and lets the sign-in pass run to its end: it fetches an auto-join bookmark for
    /// `room` and joins it, then joins `remembered`. Bob is in every joined room.
    func signIn(remembering remembered: BareJID? = nil) async throws {
        try await connectFresh(on: transports[0], remembering: remembered)
        try await answerBookmarksFetch(on: transports[0], autoJoin: [room])
        try await completeJoin(of: room, on: transports[0])
        if let remembered {
            try await completeJoin(of: remembered, on: transports[0])
        }
        try await awaitSignInPass()
    }

    func connectFresh(on transport: MockTransport, remembering remembered: BareJID? = nil) async throws {
        accountID = try await environment.accountService.createAccount(jidString: testJIDString, host: "example.com", port: 5222, requireTLS: false)
        if let remembered {
            await store.addConversation(Conversation(
                id: UUID(), accountID: accountID, jid: remembered, type: .groupchat,
                isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: "alice", rejoinsOnConnect: true, createdAt: Date()
            ))
        }
        let connection = Task { try await self.environment.accountService.connect(accountID: self.accountID, password: "secret") }
        await authenticate(on: transport)
        await bindSession(on: transport, sentBefore: 3)
        try await connection.value
    }

    /// Reconnects on `transport`, where the server rejects the resume and binds a fresh session.
    func reconnectFresh(on transport: MockTransport) async throws {
        let reconnect = Task { try await self.environment.accountService.connect(accountID: self.accountID, password: "secret") }
        await authenticate(on: transport)
        await transport.waitForSent(count: 4) // <resume> sent
        await transport.simulateReceive("<failed xmlns='urn:xmpp:sm:3'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></failed>")
        await bindSession(on: transport, sentBefore: 4)
        try await reconnect.value
    }

    /// Reconnects on `transport`, where the server resumes the stream and acknowledges everything the dropped client
    /// sent. `replay` arrives while the resume is parked ahead of `.streamResumed`, and `beforeAnnouncing` runs
    /// before it is let go.
    func resume(on transport: MockTransport, replaying replay: String = "", beforeAnnouncing: () async throws -> Void = {}) async throws {
        let reconnect = Task { try await self.environment.accountService.connect(accountID: self.accountID, password: "secret") }
        await authenticate(on: transport)
        await transport.waitForSent(count: 4) // <resume> sent
        let carried = try #require(await factory.lastResuming)
        await transport.simulateReceive("<resumed xmlns='urn:xmpp:sm:3' previd='room-session-\(sessions)' h='\(carried.streamManagement.outgoingCounter)'/>")
        try #require(try await boundedOutcome { await self.resumeGate.entered.wait() } != nil)
        if !replay.isEmpty {
            await transport.simulateReceive(replay)
        }
        try await beforeAnnouncing()
        await resumeGate.release.signal()
        try await reconnect.value
    }

    /// Cuts `transport`'s connection and waits until the dropped session's rooms are cleared.
    func drop(_ transport: MockTransport) async throws {
        await transport.simulateDisconnect()
        try await awaitDropped()
    }

    func awaitDropped() async throws {
        try await eventually { self.environment.accountService.client(for: self.accountID) == nil && self.participants(in: room).isEmpty }
    }

    /// What the account's latest client was built to take over.
    var carried: StreamResumeContext? {
        get async { await factory.lastResuming }
    }

    func isRemembered(_ room: BareJID) async throws -> Bool {
        try await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)?.rejoinsOnConnect ?? false
    }

    func close() async {
        await environment.accountService.disconnect(accountID: accountID)
        await environment.shutdown(within: .seconds(2))
    }

    private func authenticate(on transport: MockTransport) async {
        await transport.waitForSent(count: 1) // stream opening sent
        await transport.simulateReceive(testServerStreamOpen + testFeaturesNoTLS)
        await transport.waitForSent(count: 2) // auth element sent
        await transport.simulateReceive("<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        await transport.waitForSent(count: 3) // post-auth stream opening sent
        await transport.simulateReceive(testServerStreamOpen + testFeaturesBindWithSM)
    }

    private func bindSession(on transport: MockTransport, sentBefore count: Int) async {
        await transport.waitForSent(count: count + 1) // bind IQ sent
        await transport.simulateReceive(testBindResult)
        await transport.waitForSent(count: count + 2) // SM <enable> sent
        sessions += 1
        await transport.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='room-session-\(sessions)' max='300'/>")
    }

    // MARK: Sign-In Pass

    /// Completes the join of `room` that went out on `transport`, with bob already in the room.
    func completeJoin(of room: BareJID, on transport: MockTransport) async throws {
        _ = try await sentStanza(on: transport, containing: "to=\"\(room)/alice\"")
        await transport.simulateReceive(occupantPresence("bob", in: room) + occupantPresence("alice", in: room, statusCodes: [110, 100]))
        try await eventually { self.participants(in: room) == ["alice", "bob"] }
    }

    /// Answers the sign-in pass's bookmarks fetch on `transport` with an error.
    func failBookmarksFetch(on transport: MockTransport) async throws {
        let fetch = try await sentStanza(on: transport, containing: XMPPNamespaces.bookmarks2)
        let id = try #require(extractIQID(from: fetch))
        await transport.simulateReceive("""
        <iq type='error' id='\(id)'>\
        <error type='wait'><internal-server-error xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>\
        </iq>
        """)
    }

    func awaitSignInPass() async throws {
        try await eventually { self.environment.bookmarksService.completedSignInPass.contains(self.accountID) }
    }
}

/// Builds each client on the next transport, with fresh modules seeded from what the dropped client left behind.
private actor RoomResumeFactory: XMPPClientFactory {
    private let transports: [MockTransport]
    private let gate: ResumeGate
    private var index = 0
    private(set) var lastResuming: StreamResumeContext?

    init(transports: [MockTransport], gate: ResumeGate) {
        self.transports = transports
        self.gate = gate
    }

    func makeClient(account: Account, password: String, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?) async -> (XMPPClient, StreamManagementModule) {
        let transport = transports[index]
        index += 1
        lastResuming = resuming
        var builder = XMPPClientBuilder(domain: account.jid.domainPart, username: account.jid.localPart ?? "", password: password)
        builder.withTransport(transport)
        builder.withRequireTLS(false)
        let sm = StreamManagementModule(previousState: resuming?.streamManagement)
        builder.withModule(sm)
        builder.withInterceptor(sm)
        builder.withModule(MUCModule(resuming: resuming?.rooms))
        let pep = PEPModule()
        pep.registerNotifyInterest(XMPPNamespaces.bookmarks2)
        builder.withModule(pep)
        builder.withModule(gate)
        // A requested disconnect waits for the server to acknowledge what was sent.
        await transport.ackSyncRequests(from: sm)
        return await (builder.build(), sm)
    }
}
