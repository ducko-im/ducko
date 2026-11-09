import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

private func makeConnectedClient(mock: MockTransport) async throws -> (XMPPClient, MUCModule) {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    let module = MUCModule()
    await client.register(module)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return (client, module)
}

private func selfPresence(statusCodes: [Int] = [110]) -> String {
    let statuses = statusCodes.map { "<status code='\($0)'/>" }.joined()
    return """
    <presence from='room@conference.example.com/me'><x xmlns='http://jabber.org/protocol/muc#user'>\
    <item affiliation='owner' role='moderator'/>\(statuses)</x></presence>
    """
}

/// The `<query/>` of a room's disco#info answer that advertises occupant ids.
private let occupantIDRoomInfo = discoInfoQuery(features: [XMPPNamespaces.occupantID])

/// A room module driven without a client, whose room advertises occupant ids.
private func makeOccupantIDRoomModule(resuming: MUCResumeState? = nil) -> MUCModule {
    makeStubbedRoomModule(resuming: resuming) { occupantIDRoomInfo }
}

private func joinConfirmed(_ module: MUCModule) async throws {
    try await module.joinRoom(testRoomJID, nickname: "me")
    try module.handlePresence(XMPPPresence(element: stanza(selfPresence())))
}

// MARK: - Tests

enum MUCModuleRoomInfoTests {
    struct JoinQuery {
        @Test
        func `A join goes out only once the room's disco answer is stored`() async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)

            let join = Task { try await module.joinRoom(testRoomJID, nickname: "me") }
            let query = try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.discoInfo) {
                $0.contains("to=\"room@conference.example.com\"")
            }
            let sentBeforeAnswer = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sentBeforeAnswer.contains { $0.hasPrefix("<presence") })

            await mock.simulateReceive("""
            <iq type='result' id='\(query.id)' from='room@conference.example.com'>\
            <query xmlns='\(XMPPNamespaces.discoInfo)'><feature var='\(XMPPNamespaces.occupantID)'/></query>\
            </iq>
            """)
            #expect(await mock.waitForSent { $0.hasPrefix("<presence") } != nil)
            #expect(module.knownRoomInfo(for: testRoomJID)?.features.contains(XMPPNamespaces.occupantID) == true)
            try await join.value

            await disconnectFast(client)
        }

        @Test
        func `A room that does not answer holds the join for at most two seconds, and its features stay unknown`() async throws {
            let mock = MockTransport()
            let (client, module) = try await makeConnectedClient(mock: mock)
            let started = ContinuousClock.now

            try await module.joinRoom(testRoomJID, nickname: "me")

            #expect(ContinuousClock.now - started < .seconds(4))
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.contains { $0.hasPrefix("<presence") })
            #expect(module.knownRoomInfo(for: testRoomJID) == nil)

            await disconnectFast(client)
        }

        @Test
        func `A room created by the join is asked again once it exists`() async throws {
            let exists = OSAllocatedUnfairLock(initialState: false)
            let module = makeStubbedRoomModule {
                guard exists.withLock({ $0 }) else {
                    throw XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
                }
                return occupantIDRoomInfo
            }
            try await module.joinRoom(testRoomJID, nickname: "me")
            #expect(module.knownRoomInfo(for: testRoomJID) == nil)

            exists.withLock { $0 = true }
            try module.handlePresence(XMPPPresence(element: stanza(selfPresence(statusCodes: [110, 201]))))

            try await eventually { module.knownRoomInfo(for: testRoomJID) != nil }
        }
    }

    struct StoredInfo {
        /// A room that changed its features since it last answered is not trusted on its old answer.
        @Test(arguments: [true, false])
        func `A rejoin asks the room again, and an unanswered one leaves its features unknown`(answersAgain: Bool) async throws {
            let joins = OSAllocatedUnfairLock(initialState: 0)
            let module = makeStubbedRoomModule {
                let join = joins.withLock { count in
                    count += 1
                    return count
                }
                guard join == 1 else {
                    guard answersAgain else { throw XMPPStanzaError(errorType: .cancel, condition: .serviceUnavailable) }
                    return discoInfoQuery(features: [])
                }
                return occupantIDRoomInfo
            }
            try await joinConfirmed(module)

            try await module.rejoinRoom(testRoomJID, nickname: "me")

            #expect(module.confirmedNickname(in: testRoomJID) == nil)
            #expect(module.knownRoomInfo(for: testRoomJID)?.features.contains(XMPPNamespaces.occupantID) == (answersAgain ? false : nil))
        }

        @Test(arguments: [true, false])
        func `The room info carried for a resume is kept only when the stream resumes`(resumed: Bool) async throws {
            let dropped = makeOccupantIDRoomModule()
            try await joinConfirmed(dropped)
            await dropped.handleDisconnect()

            let next = makeOccupantIDRoomModule(resuming: dropped.resumeState)
            next.handleSessionEstablished(resumed: resumed)

            #expect((next.knownRoomInfo(for: testRoomJID) != nil) == resumed)
        }
    }
}
