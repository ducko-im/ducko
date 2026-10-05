import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private let selfPresence = """
<presence from='room@conference.example.com/me'>\
<x xmlns='http://jabber.org/protocol/muc#user'>\
<item affiliation='member' role='participant'/>\
<status code='110'/>\
<status code='100'/>\
</x>\
</presence>
"""

private let groupMessage = "<message type='groupchat' from='room@conference.example.com/other'><body>Hello group!</body></message>"

private func occupantPresence(_ nickname: String) -> String {
    """
    <presence from='room@conference.example.com/\(nickname)'>\
    <x xmlns='http://jabber.org/protocol/muc#user'>\
    <item affiliation='member' role='participant'/>\
    </x>\
    </presence>
    """
}

/// Parses one stanza as a client's stream would deliver it.
private func stanza(_ xml: String) throws -> XMLElement {
    let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
    for case let .stanzaReceived(element) in events {
        return element
    }
    throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
}

/// A room module driven without a client, recording the events it emits.
private struct ModuleHarness {
    let module: MUCModule
    private let recorded = OSAllocatedUnfairLock(initialState: [XMPPEvent]())
    private let refusesSends = OSAllocatedUnfairLock(initialState: false)

    var events: [XMPPEvent] {
        recorded.withLock { $0 }
    }

    init(selfPingInterval: Duration = .seconds(900), resuming: MUCResumeState? = nil, sendIQ: @escaping ModuleContext.IQSender = { _, _ in nil }) {
        self.module = MUCModule(selfPingInterval: selfPingInterval, resuming: resuming)
        module.setUp(makeStubModuleContext(
            sendStanza: { [refusesSends] _, onAccepted in
                if refusesSends.withLock({ $0 }) { throw XMPPClientError.notConnected }
                onAccepted?()
            },
            sendIQ: sendIQ,
            emitEvent: { [recorded] event in recorded.withLock { $0.append(event) } }
        ))
    }

    /// Makes the stub client refuse every stanza from here on, as a client without a connection does.
    func refuseSends() {
        refusesSends.withLock { $0 = true }
    }

    func receivePresence(_ xml: String) throws {
        try module.handlePresence(XMPPPresence(element: stanza(xml)))
    }

    func receiveMessage(_ xml: String) throws {
        try module.handleMessage(XMPPMessage(element: stanza(xml)))
    }

    /// Joins the test room with another occupant in it and a subject set.
    static func joinedSession() async throws -> ModuleHarness {
        let harness = ModuleHarness()
        try await harness.module.joinRoom(testRoomJID, nickname: "me")
        try harness.receivePresence(occupantPresence("other"))
        try harness.receivePresence(selfPresence)
        try harness.receiveMessage("<message type='groupchat' from='room@conference.example.com/other'><subject>Topic</subject></message>")
        return harness
    }

    /// A joined session torn down as a drop does. `lastPresence` arrives just before the drop.
    static func droppedSession(lastPresence: String? = nil) async throws -> ModuleHarness {
        let harness = try await joinedSession()
        if let lastPresence {
            try harness.receivePresence(lastPresence)
        }
        await harness.module.handleDisconnect()
        return harness
    }
}

private func makeStreamManagedClient(mock: MockTransport, sm: StreamManagementModule, muc: MUCModule) async -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(sm)
    await client.addInterceptor(sm)
    await client.register(muc)
    return client
}

/// A connected client with stream management enabled, whose room module is `muc`.
private func makeConnectedClient(mock: MockTransport, muc: MUCModule) async throws -> (XMPPClient, StreamManagementModule) {
    let sm = StreamManagementModule()
    let client = await makeStreamManagedClient(mock: mock, sm: sm, muc: muc)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock, postAuthFeatures: testFeaturesBindWithSM)
    await mock.waitForSent(count: 5) // SM <enable> sent
    await mock.simulateReceive("<enabled xmlns='urn:xmpp:sm:3' id='sm-resume-1' max='300'/>")
    try await connectTask.value

    return (client, sm)
}

/// Records which rooms the room module tracked when the fresh session's connect hooks ran, right after `.connected`
/// was announced.
private final class TrackedRoomsProbe: XMPPModule, Sendable {
    private let muc: MUCModule
    private let recorded = OSAllocatedUnfairLock<[BareJID]?>(initialState: nil)

    var roomsAtConnect: [BareJID]? {
        recorded.withLock { $0 }
    }

    init(muc: MUCModule) {
        self.muc = muc
    }

    func setUp(_: ModuleContext) {}

    func handleConnect() async throws {
        recorded.withLock { $0 = Array(muc.roomOccupancies.keys) }
    }
}

/// Joins the test room on a stream-managed client, drops its connection, and returns a client seeded with what the
/// dropped one left behind.
private func makeResumingClient(mock: MockTransport) async throws -> (XMPPClient, MUCModule) {
    let droppedMock = MockTransport()
    let muc = MUCModule()
    let (dropped, sm) = try await makeConnectedClient(mock: droppedMock, muc: muc)
    try await muc.joinRoom(testRoomJID, nickname: "me")
    await droppedMock.simulateReceive(selfPresence)
    await droppedMock.simulateDisconnect()
    _ = try await collectEvents(from: dropped) { event in
        if case .disconnected = event { return true }
        return false
    }

    let resumingMUC = MUCModule(resuming: muc.resumeState)
    let client = await makeStreamManagedClient(mock: mock, sm: StreamManagementModule(previousState: sm.resumeState), muc: resumingMUC)
    return (client, resumingMUC)
}

// MARK: - Tests

enum MUCModuleResumeTests {
    struct CarriedRooms {
        @Test
        func `A module seeded from a dropped session's rooms keeps them on a resumed session`() async throws {
            let dropped = try await ModuleHarness.droppedSession()

            let resumed = ModuleHarness(resuming: dropped.module.resumeState)
            resumed.module.handleSessionEstablished(resumed: true)

            let occupancy = try #require(resumed.module.roomOccupancies[testRoomJID])
            #expect(occupancy.nickname == "me")
            #expect(Set(occupancy.occupants.map(\.nickname)) == ["me", "other"])
            #expect(occupancy.subject == "Topic")
            #expect(occupancy.flags == [.nonAnonymous])

            try resumed.receiveMessage(groupMessage)
            try resumed.receivePresence(occupantPresence("newcomer"))
            #expect(resumed.events.contains { if case .roomMessageReceived = $0 { true } else { false } })
            #expect(resumed.events.contains { if case .roomOccupantJoined = $0 { true } else { false } })
        }

        @Test
        func `A fresh session discards the rooms carried for a resume`() async throws {
            let dropped = try await ModuleHarness.droppedSession()

            let fresh = ModuleHarness(resuming: dropped.module.resumeState)
            fresh.module.handleSessionEstablished(resumed: false)

            #expect(fresh.module.roomOccupancies.isEmpty)
            #expect(fresh.module.nickname(in: testRoomJID) == nil)
            try fresh.receiveMessage(groupMessage)
            #expect(fresh.events.isEmpty)
        }

        @Test
        func `A nickname change that began before the drop completes on the resumed session`() async throws {
            let dropped = try await ModuleHarness.droppedSession(lastPresence: """
            <presence type='unavailable' from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' nick='renamed'/>\
            <status code='303'/>\
            </x>\
            </presence>
            """)

            let resumed = ModuleHarness(resuming: dropped.module.resumeState)
            resumed.module.handleSessionEstablished(resumed: true)
            try resumed.receivePresence(occupantPresence("renamed"))

            guard case let .roomOccupantNickChanged(_, oldNickname, occupant) = resumed.events.last else {
                Issue.record("Expected roomOccupantNickChanged, got \(resumed.events)")
                return
            }
            #expect(oldNickname == "other")
            #expect(occupant.nickname == "renamed")
        }

        @Test
        func `A resumed session pings itself in a carried room again`() async throws {
            let dropped = try await ModuleHarness.droppedSession()
            let pings = AsyncStream.makeStream(of: JID?.self)

            let resumed = ModuleHarness(selfPingInterval: .milliseconds(10), resuming: dropped.module.resumeState) { iq, _ in
                pings.continuation.yield(iq.to)
                return nil
            }
            resumed.module.handleSessionEstablished(resumed: true)
            try await resumed.module.handleResume()

            let pinged = try await boundedOutcome {
                for await target in pings.stream where target?.description == "room@conference.example.com/me" {
                    return
                }
            }
            #expect(pinged != nil)

            await resumed.module.handleDisconnect()
        }
    }

    struct SendAcceptance {
        @Test
        func `A join the client refuses for lack of a connection is not tracked`() async throws {
            let harness = ModuleHarness()
            harness.refuseSends()

            await #expect(throws: XMPPClientError.self) {
                try await harness.module.joinRoom(testRoomJID, nickname: "me")
            }

            #expect(harness.module.nickname(in: testRoomJID) == nil)
            #expect(MUCModule(resuming: harness.module.resumeState).nickname(in: testRoomJID) == nil)
        }

        @Test
        func `A refused join of a room already joined leaves the room as it was`() async throws {
            let harness = try await ModuleHarness.joinedSession()
            harness.refuseSends()

            await #expect(throws: XMPPClientError.self) {
                try await harness.module.joinRoom(testRoomJID, nickname: "renamed")
            }

            let occupancy = try #require(harness.module.roomOccupancies[testRoomJID])
            #expect(occupancy.nickname == "me")
            #expect(Set(occupancy.occupants.map(\.nickname)) == ["me", "other"])
            #expect(occupancy.subject == "Topic")
        }

        @Test
        func `A refused leave keeps the room tracked, since a resumed stream is still in it`() async throws {
            let harness = try await ModuleHarness.joinedSession()
            harness.refuseSends()

            await #expect(throws: XMPPClientError.self) {
                try await harness.module.leaveRoom(testRoomJID)
            }

            #expect(harness.module.nickname(in: testRoomJID) == "me")
            #expect(MUCModule(resuming: harness.module.resumeState).nickname(in: testRoomJID) == "me")
        }

        @Test(arguments: [XMPPClientError.sendFailed("The connection closed before the data could be sent"), .notConnected])
        func `A join whose write fails stays tracked, since stream management re-sends it on a resume`(writeError: XMPPClientError) async throws {
            let mock = MockTransport()
            let muc = MUCModule()
            let (client, sm) = try await makeConnectedClient(mock: mock, muc: muc)
            await mock.failNextSend(matching: "<presence", error: writeError)

            await #expect(throws: XMPPClientError.self) {
                try await muc.joinRoom(testRoomJID, nickname: "me")
            }

            let queued = sm.resumeState?.outgoingQueue ?? []
            #expect(queued.contains { $0.name == "presence" })
            #expect(muc.nickname(in: testRoomJID) == "me")
            #expect(MUCModule(resuming: muc.resumeState).nickname(in: testRoomJID) == "me")

            await disconnectFast(client)
        }

        @Test
        func `A join is tracked before its write completes, so a reply that overtakes the write is not dropped`() async throws {
            let mock = MockTransport()
            let muc = MUCModule()
            let (client, _) = try await makeConnectedClient(mock: mock, muc: muc)
            await mock.blockSends { $0.hasPrefix("<presence") }
            let join = Task { try await muc.joinRoom(testRoomJID, nickname: "me") }
            try #require(try await boundedOutcome { await mock.waitForBlockedSend() } != nil)

            await mock.simulateReceive(selfPresence)

            let events = try await collectEvents(from: client) { event in
                if case .roomJoined = event { return true }
                return false
            }
            #expect(events.contains { if case .roomJoined = $0 { true } else { false } })
            await mock.releaseBlockedSends()
            try await join.value

            await disconnectFast(client)
        }

        @Test
        func `A join sent while the client tears down is refused, since stream management no longer queues it`() async throws {
            let mock = MockTransport()
            let muc = MUCModule()
            let (client, sm) = try await makeConnectedClient(mock: mock, muc: muc)
            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await mock.installDisconnectGate(entered: entered, release: release)
            await mock.simulateDisconnect()
            // The teardown is parked closing the transport: the module hooks have run and the client is not yet disconnected.
            try #require(try await boundedOutcome { await entered.wait() } != nil)

            await #expect(throws: XMPPClientError.self) {
                try await muc.joinRoom(testRoomJID, nickname: "me")
            }

            #expect(!(sm.resumeState?.outgoingQueue ?? []).contains { $0.name == "presence" })
            #expect(muc.nickname(in: testRoomJID) == nil)

            await release.signal()
            _ = try await collectEvents(from: client) { event in
                if case .disconnected = event { return true }
                return false
            }
        }
    }

    struct ClientSession {
        @Test
        func `A room message arriving with the resume acknowledgement is emitted`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makeResumingClient(mock: mock)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateResumeConnect(mock, resumeResponse: "<resumed xmlns='urn:xmpp:sm:3' previd='sm-resume-1' h='1'/>" + groupMessage)
            try await connectTask.value

            let events = try await collectEvents(from: client) { event in
                if case .roomMessageReceived = event { return true }
                return false
            }
            guard case let .roomMessageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomMessageReceived event")
            }
            #expect(message.body == "Hello group!")

            await disconnectFast(client)
        }

        @Test
        func `A rejected resume leaves no room tracked by the time the session is announced`() async throws {
            let mock = MockTransport()
            let (client, muc) = try await makeResumingClient(mock: mock)
            #expect(muc.nickname(in: testRoomJID) == "me")
            let probe = TrackedRoomsProbe(muc: muc)
            await client.register(probe)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateResumeFailConnect(mock)
            try await connectTask.value

            #expect(probe.roomsAtConnect == [])

            await disconnectFast(client)
        }
    }
}
