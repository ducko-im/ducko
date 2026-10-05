import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!
private let otherRoomJID = BareJID(localPart: "other", domainPart: "conference.example.com")!

/// A connected client whose room module pings itself every few milliseconds.
private func makeConnectedClient(mock: MockTransport) async throws -> (XMPPClient, MUCModule) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    let module = MUCModule(selfPingInterval: .milliseconds(10))
    await client.register(module)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return (client, module)
}

/// Joins `room` as "me" and delivers the self-presence that starts its self-ping.
private func join(_ room: BareJID, module: MUCModule, mock: MockTransport) async throws {
    try await module.joinRoom(room, nickname: "me")
    await mock.simulateReceive("""
    <presence from='\(room)/me'>\
    <x xmlns='http://jabber.org/protocol/muc#user'>\
    <item affiliation='member' role='participant'/>\
    <status code='110'/>\
    </x>\
    </presence>
    """)
}

/// Waits for a self-ping to `room` other than the ones in `answered`, and returns its id.
private func awaitSelfPing(to room: BareJID, on mock: MockTransport, after answered: [String] = []) async throws -> String {
    try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.ping) { stanza in
        stanza.contains("to=\"\(room)/me\"") && !answered.contains { stanza.contains("id=\"\($0)\"") }
    }.id
}

/// Answers the self-ping `id` with `condition` from the occupant JID that was pinged, as `IQReplyPolicy` requires.
private func failSelfPing(_ id: String, to room: BareJID, condition: String, on mock: MockTransport) async {
    await mock.simulateReceive("""
    <iq type='error' id='\(id)' from='\(room)/me'>\
    <error type='cancel'><\(condition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error>\
    </iq>
    """)
}

/// `not-acceptable`, and every condition XEP-0410 does not name.
private let notJoinedConditions = [
    "not-acceptable", "bad-request", "conflict", "forbidden", "gone", "internal-server-error", "jid-malformed",
    "not-allowed", "not-authorized", "policy-violation", "recipient-unavailable", "redirect", "registration-required",
    "resource-constraint", "subscription-required", "undefined-condition", "unexpected-request"
]

// MARK: - Tests

enum MUCSelfPingTests {
    struct Ping {
        @Test
        func `A joined room is pinged at the own occupant after the interval`() async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)

            try await join(testRoomJID, module: module, mock: mock)

            _ = try await awaitSelfPing(to: testRoomJID, on: mock)

            await disconnectFast(client)
        }

        @Test
        func `Leaving one room stops its pings and keeps the other room's`() async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)
            try await join(testRoomJID, module: module, mock: mock)
            try await join(otherRoomJID, module: module, mock: mock)
            // The left room's ping stays unanswered, so its loop is waiting for the reply when the room is left.
            let pending = try await awaitSelfPing(to: testRoomJID, on: mock)
            var answered = try await [awaitSelfPing(to: otherRoomJID, on: mock)]

            try await module.leaveRoom(testRoomJID)
            await mock.clearSentBytes()
            // A loop the leave left running would take this reply as the room no longer being joined, and report it.
            await failSelfPing(pending, to: testRoomJID, condition: "not-acceptable", on: mock)
            for _ in 0 ..< 2 {
                await mock.simulateReceive("<iq type='result' id='\(answered[answered.count - 1])' from='\(otherRoomJID)/me'/>")
                let next = try await awaitSelfPing(to: otherRoomJID, on: mock, after: answered)
                answered.append(next)
            }
            await mock.simulateReceive("<message type='groupchat' from='\(otherRoomJID)/other'><body>Still here</body></message>")

            let events = try await collectEvents(from: client) { event in
                if case .roomMessageReceived = event { return true }
                return false
            }
            #expect(!events.contains { if case .mucSelfPingFailed = $0 { true } else { false } })
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("to=\"\(testRoomJID)/me\"") })

            await disconnectFast(client)
        }
    }

    struct PingErrors {
        @Test(arguments: notJoinedConditions.map { ($0, true) } + [("item-not-found", false)])
        func `An error that says the room is no longer joined is reported`(condition: String, rejoins: Bool) async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)
            try await join(testRoomJID, module: module, mock: mock)
            let ping = try await awaitSelfPing(to: testRoomJID, on: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .mucSelfPingFailed = event { return true }
                    return false
                }
            }
            await failSelfPing(ping, to: testRoomJID, condition: condition, on: mock)

            let events = try await eventsTask.value
            guard case let .mucSelfPingFailed(room, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected mucSelfPingFailed event")
            }
            #expect(room == testRoomJID)
            switch reason {
            case .notJoined:
                #expect(rejoins)
            case let .nickChanged(nickname):
                #expect(!rejoins)
                #expect(nickname == "me")
            }

            await disconnectFast(client)
        }

        @Test(arguments: ["service-unavailable", "feature-not-implemented", "remote-server-not-found", "remote-server-timeout"])
        func `An error that leaves the room joined is not reported`(condition: String) async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)
            try await join(testRoomJID, module: module, mock: mock)
            let ping = try await awaitSelfPing(to: testRoomJID, on: mock)

            await failSelfPing(ping, to: testRoomJID, condition: condition, on: mock)
            // The error is handled before the next ping goes out, and a report of it would precede this message's event.
            _ = try await awaitSelfPing(to: testRoomJID, on: mock, after: [ping])
            await mock.simulateReceive("<message type='groupchat' from='\(testRoomJID)/other'><body>Still here</body></message>")

            let events = try await collectEvents(from: client) { event in
                if case .roomMessageReceived = event { return true }
                return false
            }
            #expect(!events.contains { if case .mucSelfPingFailed = $0 { true } else { false } })

            await disconnectFast(client)
        }
    }
}
