// Split candidate.
// swiftlint:disable file_length
import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(MUCModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private let testRoomJID = BareJID(localPart: "room", domainPart: "conference.example.com")!

// MARK: - Tests

enum MUCModuleTests { // swiftlint:disable:this type_body_length
    struct JoinFlow {
        @Test
        func `Self-presence with status 110 emits roomJoined`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            // Other occupant arrives first
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)

            // Self-presence with status 110
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(room, occupancy, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            #expect(room == testRoomJID)
            #expect(occupancy.nickname == "me")
            #expect(occupancy.occupants.count == 2)

            await disconnectFast(client)
        }
    }

    struct NicknameNormalization {
        @Test
        func `joinRoom stores the OpaqueString-normalized nickname`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "Ni\u{00A0}ck") // NO-BREAK SPACE
            #expect(module.nickname(in: testRoomJID) == "Ni ck")

            await disconnectFast(client)
        }

        @Test
        func `joinRoom rejects a nickname that fails to normalize`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await #expect(throws: MUCModule.MUCError.self) {
                try await module.joinRoom(testRoomJID, nickname: "bad\u{0007}nick")
            }

            await disconnectFast(client)
        }

        @Test
        func `Admin operations reject a nickname that fails to normalize`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            // kick/grantVoice/revokeVoice all route through setRole, which normalizes the nick.
            await #expect(throws: MUCModule.MUCError.self) {
                try await module.kickOccupant(nickname: "bad\u{0007}nick", from: testRoomJID)
            }

            await disconnectFast(client)
        }

        @Test
        func `Admin operations normalize the target nickname in the sent IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            try await withIQOperation(client: client, operation: {
                try await module.kickOccupant(nickname: "Ni\u{00A0}ck", from: testRoomJID) // NO-BREAK SPACE
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#admin") {
                    $0.contains("nick=\"Ni ck\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml
                #expect(sent.contains("nick=\"Ni ck\""))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }

        @Test
        func `Normalized self-presence matches the stored nickname for leave detection`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "Ni\u{00A0}ck")

            // Self-presence echo carries the OpaqueString-normalized nickname (ASCII space), parsed via FullJID.
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/Ni ck'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let leaveTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            // Self-leave matches the stored normalized nickname → room is removed.
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/Ni ck'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='none'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            _ = try await leaveTask.value
            #expect(module.nickname(in: testRoomJID) == nil)

            await disconnectFast(client)
        }
    }

    struct JoinedRoomFullJIDs {
        @Test
        func `Returns empty when no rooms joined`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            #expect(module.joinedRoomFullJIDs.isEmpty)

            await disconnectFast(client)
        }

        @Test
        func `Returns full JIDs for joined rooms`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let fullJIDs = module.joinedRoomFullJIDs
            #expect(fullJIDs.count == 1)
            #expect(fullJIDs.first?.description == "room@conference.example.com/me")

            await disconnectFast(client)
        }
    }

    struct RoomFlags {
        @Test
        func `Non-anonymous room flag from status code 100`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            <status code='100'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(_, occupancy, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            #expect(occupancy.flags.contains(.nonAnonymous))
            #expect(!occupancy.flags.contains(.logged))

            await disconnectFast(client)
        }

        @Test
        func `Logged room flag from status code 170`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            <status code='170'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(_, occupancy, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            #expect(!occupancy.flags.contains(.nonAnonymous))
            #expect(occupancy.flags.contains(.logged))

            await disconnectFast(client)
        }
    }

    struct OccupantJoin {
        @Test
        func `Available presence emits roomOccupantJoined`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantJoined = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/newcomer'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantJoined(room, occupant) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantJoined event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "newcomer")
            #expect(occupant.role == .participant)

            await disconnectFast(client)
        }
    }

    struct OccupantLeave {
        @Test
        func `Unavailable presence emits roomOccupantLeft`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // First make occupant join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/leaver'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            // Occupant leaves
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/leaver'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='none'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(room, occupant, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "leaver")
            #expect(reason == nil)

            await disconnectFast(client)
        }
    }

    struct GroupMessage {
        @Test
        func `Groupchat message emits roomMessageReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomMessageReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/other'>\
            <body>Hello group!</body>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomMessageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomMessageReceived event")
            }
            #expect(message.body == "Hello group!")
            #expect(message.from?.bareJID == testRoomJID)

            await disconnectFast(client)
        }
    }

    struct SubjectChange {
        @Test
        func `Subject message emits roomSubjectChanged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomSubjectChanged = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/admin'>\
            <subject>New topic</subject>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomSubjectChanged(room, subject, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomSubjectChanged event")
            }
            #expect(room == testRoomJID)
            #expect(subject == "New topic")

            await disconnectFast(client)
        }
    }

    struct MediatedInvite {
        @Test
        func `Mediated invite emits roomInviteReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='room@conference.example.com'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <invite from='admin@example.com'>\
            <reason>Join us!</reason>\
            </invite>\
            </x>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomInviteReceived(invite) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived event")
            }
            #expect(invite.room == testRoomJID)
            #expect(invite.reason == "Join us!")
            #expect(invite.isDirect == false)

            await disconnectFast(client)
        }
    }

    struct DirectInvite {
        @Test
        func `Direct invite (XEP-0249) emits roomInviteReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='admin@example.com'>\
            <x xmlns='jabber:x:conference' jid='room@conference.example.com' reason='Come join'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomInviteReceived(invite) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived event")
            }
            #expect(invite.room == testRoomJID)
            #expect(invite.reason == "Come join")
            #expect(invite.isDirect == true)

            await disconnectFast(client)
        }

        @Test
        func `Direct invite with continue and thread attributes`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='admin@example.com'>\
            <x xmlns='jabber:x:conference' jid='room@conference.example.com' continue='true' thread='t1'/>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomInviteReceived(invite) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived event")
            }
            #expect(invite.room == testRoomJID)
            #expect(invite.isContinuation == true)
            #expect(invite.thread == "t1")

            await disconnectFast(client)
        }

        @Test
        func `inviteUser with continue and thread sends correct attributes`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()
            let invitee = try #require(BareJID.parse("bob@example.com"))
            try await module.inviteUser(invitee, to: testRoomJID, isContinuation: true, thread: "t1")

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sent = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sent.contains("continue=\"true\""))
            #expect(sent.contains("thread=\"t1\""))
            #expect(sent.contains(XMPPNamespaces.mucDirectInvite))

            await disconnectFast(client)
        }
    }

    struct DeclineInvite {
        @Test
        func `declineInvite sends correct stanza`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()
            let inviterJID = try #require(JID.parse("admin@example.com"))
            try await module.declineInvite(room: testRoomJID, inviter: inviterJID, reason: "Not interested")

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sent = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sent.contains("decline"))
            #expect(sent.contains("to=\"admin@example.com\""))
            #expect(sent.contains("Not interested"))
            #expect(sent.contains(XMPPNamespaces.mucUser))

            await disconnectFast(client)
        }
    }

    struct KickBan {
        @Test
        func `Kick status code 307 emits occupant left`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Add occupant first
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/troublemaker'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            // Kick presence
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/troublemaker'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='none'/>\
            <status code='307'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(room, occupant, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "troublemaker")
            #expect(reason == OccupantLeaveReason.kicked(reason: nil))

            await disconnectFast(client)
        }

        @Test
        func `Ban status code 301 with reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/spammer'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/spammer'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='outcast' role='none'>\
            <reason>spam</reason>\
            </item>\
            <status code='301'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(room, occupant, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(room == testRoomJID)
            #expect(occupant.nickname == "spammer")
            #expect(reason == .banned(reason: "spam"))

            await disconnectFast(client)
        }

        @Test
        func `Affiliation change status code 321`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='none' role='none'/>\
            <status code='321'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(_, _, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(reason == .affiliationChanged(reason: nil))

            await disconnectFast(client)
        }

        @Test
        func `Service shutdown status code 332`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            await mock.simulateReceive("""
            <presence from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantLeft = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/other'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='none'/>\
            <status code='332'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantLeft(_, _, reason) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantLeft event")
            }
            #expect(reason == .serviceShutdown)

            await disconnectFast(client)
        }
    }

    struct OwnMessageHandling {
        @Test
        func `Messages from own nickname still emit roomMessageReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomMessageReceived = event { return true }
                    return false
                }
            }

            // Server echoes back our own message
            await mock.simulateReceive("""
            <message type='groupchat' from='room@conference.example.com/me'>\
            <body>My message</body>\
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .roomMessageReceived(message) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomMessageReceived event")
            }
            #expect(message.body == "My message")

            await disconnectFast(client)
        }
    }

    struct RoomDiscovery {
        @Test
        func `discoverRooms parses disco#items response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            let rooms = try await withIQOperation(client: client, operation: {
                try await module.discoverRooms(on: "conference.example.com")
            }, respond: {
                // Wait for IQ to be sent, then respond
                let request = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#items") {
                    $0.contains("to=\"conference.example.com\"") && $0.contains("to=\"conference.example.com\"")
                }
                let iqID = request.id

                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='conference.example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#items'>\
                <item jid='room@conference.example.com' name='General Chat'/>\
                <item jid='dev@conference.example.com' name='Development'/>\
                </query>\
                </iq>
                """)
            })
            #expect(rooms.count == 2)
            #expect(rooms[0].jid == testRoomJID)
            #expect(rooms[0].name == "General Chat")

            await disconnectFast(client)
        }
    }

    // MARK: - History Control

    struct HistoryControl {
        @Test
        func `Skip history produces maxchars and maxstanzas zero`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()
            try await module.joinRoom(testRoomJID, nickname: "me", history: .skip)

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sent = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sent.contains("maxchars"))
            #expect(sent.contains("maxstanzas"))
            #expect(sent.contains("history"))

            await disconnectFast(client)
        }

        @Test
        func `Since history produces since attribute`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()
            try await module.joinRoom(testRoomJID, nickname: "me", history: .since("2024-01-01T00:00:00Z"))

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sent = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sent.contains("since"))
            #expect(sent.contains("2024-01-01T00:00:00Z"))

            await disconnectFast(client)
        }

        @Test
        func `Initial history omits history element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            await mock.clearSentBytes()
            try await module.joinRoom(testRoomJID, nickname: "me", history: .initial)

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sent = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            let containsHistory = sent.contains("<history")
            #expect(!containsHistory)

            await disconnectFast(client)
        }
    }

    // MARK: - Room Creation (Status 201)

    struct RoomCreation {
        @Test
        func `Self-presence with status 201 emits roomJoined with isNewlyCreated true`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            // Self-presence with status 110 + 201 (new room created)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='owner' role='moderator'/>\
            <status code='110'/>\
            <status code='201'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(room, occupancy, isNewlyCreated) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            #expect(room == testRoomJID)
            #expect(occupancy.nickname == "me")
            #expect(isNewlyCreated)

            await disconnectFast(client)
        }

        @Test
        func `Regular join emits roomJoined with isNewlyCreated false`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomJoined = event { return true }
                    return false
                }
            }

            // Self-presence with only status 110 (no 201)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomJoined(_, _, isNewlyCreated) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomJoined event")
            }
            let created = isNewlyCreated
            #expect(!created)

            await disconnectFast(client)
        }
    }

    // MARK: - Nickname Change (Status 303)

    struct NicknameChange {
        @Test
        func `Status 303 then available produces roomOccupantNickChanged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Add occupant
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/oldnick'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomOccupantNickChanged = event { return true }
                    return false
                }
            }

            // Unavailable with status 303 + new nick
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/oldnick'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' nick='newnick'/>\
            <status code='303'/>\
            </x>\
            </presence>
            """)

            // Available presence with new nick
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/newnick'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomOccupantNickChanged(room, oldNickname, occupant) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomOccupantNickChanged event")
            }
            #expect(room == testRoomJID)
            #expect(oldNickname == "oldnick")
            #expect(occupant.nickname == "newnick")

            await disconnectFast(client)
        }

        @Test
        func `Nick change does not emit spurious leave and join`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Start collecting ALL events including the initial join
            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(3)) { event in
                    if case .roomOccupantNickChanged = event { return true }
                    return false
                }
            }

            // Add alice (triggers roomOccupantJoined)
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/alice'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)

            // Nick change: unavailable with 303
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/alice'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant' nick='alice2'/>\
            <status code='303'/>\
            </x>\
            </presence>
            """)

            // New nick appears
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/alice2'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            // Expect exactly 1 roomOccupantJoined (initial alice), no roomOccupantLeft, 1 roomOccupantNickChanged
            let leftEvents = events.filter { if case .roomOccupantLeft = $0 { return true }; return false }
            let joinedEvents = events.filter { if case .roomOccupantJoined = $0 { return true }; return false }
            let nickChangeEvents = events.filter { if case .roomOccupantNickChanged = $0 { return true }; return false }
            #expect(leftEvents.isEmpty)
            #expect(joinedEvents.count == 1) // only the initial join
            #expect(nickChangeEvents.count == 1)

            await disconnectFast(client)
        }
    }

    // MARK: - Voice Management

    struct VoiceManagement {
        @Test
        func `grantVoice sends role participant`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            try await withIQOperation(client: client, operation: {
                try await module.grantVoice(nickname: "visitor1", in: testRoomJID)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#admin") {
                    $0.contains("nick=\"visitor1\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("role=\"participant\""))
                #expect(sent.contains("nick=\"visitor1\""))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }

        @Test
        func `revokeVoice sends role visitor`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            try await withIQOperation(client: client, operation: {
                try await module.revokeVoice(nickname: "talker1", in: testRoomJID)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#admin") {
                    $0.contains("nick=\"talker1\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("role=\"visitor\""))
                #expect(sent.contains("nick=\"talker1\""))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }
    }

    // MARK: - Affiliation Management

    struct AffiliationManagement {
        @Test
        func `getAffiliationList sends correct IQ and parses response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            let items = try await withIQOperation(client: client, operation: {
                try await module.getAffiliationList(.member, in: testRoomJID)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/muc#admin") {
                    $0.contains("affiliation=\"member\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("affiliation=\"member\""))
                #expect(sent.contains("muc#admin"))

                let iqID = request.id
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='room@conference.example.com'>\
                <query xmlns='http://jabber.org/protocol/muc#admin'>\
                <item jid='alice@example.com' affiliation='member' nick='alice'/>\
                <item jid='bob@example.com' affiliation='member'/>\
                </query>\
                </iq>
                """)
            })
            #expect(items.count == 2)
            #expect(items[0].jid.description == "alice@example.com")
            #expect(items[0].nickname == "alice")
            #expect(items[1].jid.description == "bob@example.com")
            #expect(items[1].nickname == nil)

            await disconnectFast(client)
        }

        @Test
        func `setAffiliation sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            let targetJID = try #require(BareJID(localPart: "user", domainPart: "example.com"))
            try await withIQOperation(client: client, operation: {
                try await module.setAffiliation(jid: targetJID, in: testRoomJID, to: .admin, reason: "Promotion")
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#admin") {
                    $0.contains("jid=\"user@example.com\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("affiliation=\"admin\""))
                #expect(sent.contains("jid=\"user@example.com\""))
                #expect(sent.contains("Promotion"))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }
    }

    // MARK: - Room Destruction

    struct RoomDestruction {
        @Test
        func `destroyRoom sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            try await withIQOperation(client: client, operation: {
                try await module.destroyRoom(testRoomJID, reason: "Closing down")
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#owner") {
                    $0.contains("<destroy") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("muc#owner"))
                #expect(sent.contains("destroy"))
                #expect(sent.contains("Closing down"))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }

        @Test
        func `Incoming destruction presence emits roomDestroyed`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Complete join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)
            try? await Task.sleep(for: .milliseconds(100))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomDestroyed = event { return true }
                    return false
                }
            }

            // Room destruction notification
            await mock.simulateReceive("""
            <presence type='unavailable' from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='none'/>\
            <status code='110'/>\
            <destroy jid='newroom@conference.example.com'>\
            <reason>Moving to a new room</reason>\
            </destroy>\
            </x>\
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .roomDestroyed(room, reason, alternate) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected roomDestroyed event")
            }
            #expect(room == testRoomJID)
            #expect(reason == "Moving to a new room")
            #expect(alternate?.description == "newroom@conference.example.com")

            await disconnectFast(client)
        }
    }

    // MARK: - Room Configuration

    struct RoomConfiguration {
        @Test
        func `getRoomConfig sends muc#owner IQ and parses form`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            let fields = try await withIQOperation(client: client, operation: {
                try await module.getRoomConfig(testRoomJID)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/muc#owner") {
                    $0.contains("<query") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("muc#owner"))

                let iqID = request.id
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='room@conference.example.com'>\
                <query xmlns='http://jabber.org/protocol/muc#owner'>\
                <x xmlns='jabber:x:data' type='form'>\
                <field var='FORM_TYPE' type='hidden'>\
                <value>http://jabber.org/protocol/muc#roomconfig</value>\
                </field>\
                <field var='muc#roomconfig_roomname' type='text-single' label='Room Name'>\
                <value>Test Room</value>\
                </field>\
                </x>\
                </query>\
                </iq>
                """)
            })
            #expect(fields.count == 2)
            let roomName = fields.first { $0.variable == "muc#roomconfig_roomname" }
            #expect(roomName?.values == ["Test Room"])

            await disconnectFast(client)
        }

        @Test
        func `acceptDefaultConfig sends empty submit form`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")
            await mock.clearSentBytes()

            try await withIQOperation(client: client, operation: {
                try await module.acceptDefaultConfig(testRoomJID)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "http://jabber.org/protocol/muc#owner") {
                    $0.contains("type=\"submit\"") && $0.contains("to=\"room@conference.example.com\"")
                }
                let sent = request.xml

                #expect(sent.contains("muc#owner"))
                #expect(sent.contains("type=\"submit\""))

                let iqID = request.id
                await mock.simulateReceive("<iq type='result' id='\(iqID)' from='room@conference.example.com'/>")
            })

            await disconnectFast(client)
        }
    }

    struct PrivateMessages {
        @Test
        func `Type chat from tracked room emits mucPrivateMessageReceived`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Self-presence to complete join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .mucPrivateMessageReceived = event { return true }
                    return false
                }
            }

            // Simulate incoming PM from another occupant
            await mock.simulateReceive("""
            <message type='chat' from='room@conference.example.com/alice' id='pm1'>\
            <body>Hello privately</body>\
            </message>
            """)

            let events = try await eventsTask.value
            let pmEvent = events.last
            guard case let .mucPrivateMessageReceived(message) = pmEvent else {
                throw XMPPClientError.unexpectedStreamState("Expected mucPrivateMessageReceived")
            }
            #expect(message.body == "Hello privately")
            #expect(message.id == "pm1")
            guard case let .full(fullJID) = message.from else {
                throw XMPPClientError.unexpectedStreamState("Expected full JID")
            }
            #expect(fullJID.resourcePart == "alice")
            #expect(fullJID.bareJID == testRoomJID)

            await disconnectFast(client)
        }

        @Test
        func `Type chat from untracked room is not emitted`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Don't join any room — room is not tracked

            let eventsTask = Task {
                try await collectEvents(from: client, timeout: .seconds(2)) { event in
                    if case .mucPrivateMessageReceived = event { return true }
                    return false
                }
            }

            // Simulate incoming message from an untracked room
            await mock.simulateReceive("""
            <message type='chat' from='other@conference.example.com/bob' id='pm2'>\
            <body>Untracked room PM</body>\
            </message>
            """)

            do {
                _ = try await eventsTask.value
                // Should timeout, not receive the event
                throw XMPPClientError.unexpectedStreamState("Should not have received event")
            } catch is XMPPClientError {
                // Expected: timeout because no mucPrivateMessageReceived was emitted
            }

            await disconnectFast(client)
        }

        @Test
        func `sendPrivateMessage builds correct stanza`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Self-presence to complete join
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            await mock.clearSentBytes()
            try await module.sendPrivateMessage(to: testRoomJID, nickname: "alice", body: "Secret message", id: "test-pm-id")
            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sent = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sent.contains("type='chat'") || sent.contains("type=\"chat\""))
            #expect(sent.contains("room@conference.example.com/alice"))
            #expect(sent.contains("Secret message"))
            #expect(sent.contains("http://jabber.org/protocol/muc#user"))

            await disconnectFast(client)
        }

        @Test
        func `Invite messages still handled before PM detection`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MUCModule.self))

            try await module.joinRoom(testRoomJID, nickname: "me")

            // Self-presence
            await mock.simulateReceive("""
            <presence from='room@conference.example.com/me'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <item affiliation='member' role='participant'/>\
            <status code='110'/>\
            </x>\
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .roomInviteReceived = event { return true }
                    return false
                }
            }

            // Mediated invite from a tracked room — should be roomInviteReceived, not mucPrivateMessageReceived
            await mock.simulateReceive("""
            <message from='room@conference.example.com'>\
            <x xmlns='http://jabber.org/protocol/muc#user'>\
            <invite from='admin@example.com'><reason>Join us</reason></invite>\
            </x>\
            </message>
            """)

            let events = try await eventsTask.value
            let lastEvent = events.last
            guard case .roomInviteReceived = lastEvent else {
                throw XMPPClientError.unexpectedStreamState("Expected roomInviteReceived, not mucPrivateMessageReceived")
            }

            await disconnectFast(client)
        }
    }
}
