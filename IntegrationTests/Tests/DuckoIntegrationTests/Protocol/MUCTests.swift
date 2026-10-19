import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MUCTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice joins an ephemeral room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                #expect(roomJID.domainPart == TestCredentials.mucService)
            }
        }

        @Test @MainActor func `Bob joins room and sees Alice as existing occupant`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                // Bob's join snapshot should include Alice as an existing occupant.
                let (_, bobJoinEvent) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")
                guard case let .roomJoined(_, occupancy, _) = bobJoinEvent else {
                    Issue.record("Expected .roomJoined event from joinRoom")
                    return
                }
                #expect(occupancy.occupants.contains { $0.nickname == "alice" })

                // Alice sees Bob join.
                let alice = try #require(harness.accounts["alice"])
                _ = try await alice.waitForEvent { event in
                    if case let .roomOccupantJoined(room, occupant) = event,
                       room == roomJID, occupant.nickname == "bob" {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice and Bob see each other leave`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobMUC = try await harness.module(MUCModule.self, for: "bob")

                harness.addCleanup { try? await bobMUC.leaveRoom(roomJID) }
                try await bobMUC.joinRoom(roomJID, nickname: "bob")

                _ = try await bob.waitForEvent { event in
                    if case let .roomJoined(room, _, _) = event, room == roomJID { return true }
                    return false
                }

                try await bobMUC.leaveRoom(roomJID)

                _ = try await alice.waitForEvent { event in
                    if case let .roomOccupantLeft(room, occupant, _, _) = event,
                       room == roomJID, occupant.nickname == "bob" {
                        return true
                    }
                    return false
                }
            }
        }

        /// The self-ping the MUC rejoin check relies on is answered from the exact occupant JID: a result while
        /// joined, an error once left. `PingModule` answers the ping when the service reflects it to the client.
        @Test @MainActor func `Occupant self-ping is answered from the occupant JID`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let probeMUC = MUCModule()
                let probe = try await harness.buildStandaloneClient(
                    for: TestCredentials.bob, resource: "probe", modules: [probeMUC, PingModule()]
                )
                let occupantJID = try #require(FullJID(bareJID: roomJID, resourcePart: "probe"))
                func selfPing() async throws -> DuckoXMPP.XMLElement? {
                    var ping = XMPPIQ(type: .get, to: .full(occupantJID), id: probe.generateID())
                    ping.element.addChild(DuckoXMPP.XMLElement(name: "ping", namespace: XMPPNamespaces.ping))
                    return try await probe.sendIQ(ping, timeout: TestTimeout.event)
                }

                harness.addCleanup { try? await probeMUC.leaveRoom(roomJID) }
                try await probeMUC.joinRoom(roomJID, nickname: "probe")
                _ = try await alice.waitForEvent { event in
                    if case let .roomOccupantJoined(room, occupant) = event, room == roomJID, occupant.nickname == "probe" {
                        return true
                    }
                    return false
                }
                _ = try await selfPing()

                try await probeMUC.leaveRoom(roomJID)
                _ = try await alice.waitForEvent { event in
                    if case let .roomOccupantLeft(room, occupant, _, _) = event, room == roomJID, occupant.nickname == "probe" {
                        return true
                    }
                    return false
                }
                await #expect(throws: XMPPStanzaError.self) { try await selfPing() }
            }
        }

        @Test @MainActor func `Alice sends a groupchat message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await aliceMUC.sendMessage(to: roomJID, body: body)

                _ = try await bob.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice sets room subject`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                let subject = "topic-\(UUID().uuidString.prefix(8))"
                try await aliceMUC.setSubject(in: roomJID, subject: subject)

                _ = try await alice.waitForEvent { event in
                    if case let .roomSubjectChanged(room, newSubject, _) = event,
                       room == roomJID, newSubject == subject {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice changes nickname in room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                let newNick = "alice-\(UUID().uuidString.prefix(8))"
                try await aliceMUC.changeNickname(in: roomJID, to: newNick)

                _ = try await alice.waitForEvent { event in
                    if case let .roomOccupantNickChanged(room, _, occupant, _) = event,
                       room == roomJID, occupant.nickname == newNick {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice invites Bob to a room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")
                let bobJID = try harness.jid(for: TestCredentials.bob)

                try await aliceMUC.inviteUser(bobJID, to: roomJID, reason: "Join us!")

                let bob = try #require(harness.accounts["bob"])
                _ = try await bob.waitForEvent { event in
                    if case let .roomInviteReceived(invite) = event, invite.room == roomJID { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice destroys the room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                let alice = try #require(harness.accounts["alice"])
                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                try await aliceMUC.destroyRoom(roomJID)

                _ = try await alice.waitForEvent { event in
                    if case let .roomDestroyed(room, _, _) = event, room == roomJID { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `Alice sends a private message to Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await aliceMUC.sendPrivateMessage(to: roomJID, nickname: "bob", body: body)

                _ = try await bob.waitForEvent { event in
                    if case let .mucPrivateMessageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service joins a room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                // Verify the service created a groupchat conversation for the room.
                let conversation = try await harness.environment.chatService.openConversation(for: roomJID, accountID: alice.accountID)
                #expect(conversation.jid == roomJID)
                #expect(conversation.type == .groupchat)
            }
        }

        @Test @MainActor func `Service sends a group message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let alice = try #require(harness.accounts["alice"])
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendGroupMessage(to: roomJID, body: body, accountID: alice.accountID)

                _ = try await bob.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == body { return true }
                    return false
                }
            }
        }

        @Test @MainActor func `Service kicks an occupant`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let alice = try #require(harness.accounts["alice"])
                try await harness.environment.chatService.kickOccupant(
                    nickname: "bob",
                    fromRoomJIDString: roomJID.description,
                    reason: "test kick",
                    accountID: alice.accountID
                )

                let kickReason = try await bob.waitForEvent(extracting: { event -> String? in
                    if case let .roomOccupantLeft(room, occupant, reason, _) = event,
                       room == roomJID, occupant.nickname == "bob",
                       case let .kicked(extractedReason?) = reason {
                        return extractedReason
                    }
                    return nil
                })
                #expect(kickReason == "test kick")
            }
        }

        @Test @MainActor func `Service bans a user`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let alice = try #require(harness.accounts["alice"])
                try await harness.environment.chatService.banUser(
                    jidString: bobJID.description,
                    fromRoomJIDString: roomJID.description,
                    reason: "test ban",
                    accountID: alice.accountID
                )

                let banReason = try await bob.waitForEvent(extracting: { event -> String? in
                    if case let .roomOccupantLeft(room, occupant, reason, _) = event,
                       room == roomJID, occupant.nickname == "bob",
                       case let .banned(extractedReason?) = reason {
                        return extractedReason
                    }
                    return nil
                })
                #expect(banReason == "test ban")
            }
        }

        @Test @MainActor func `Service configures room`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                // Get current config.
                var fields = try await harness.environment.chatService.getRoomConfig(
                    jidString: roomJID.description,
                    accountID: alice.accountID
                )
                try #require(!fields.isEmpty)

                // Find and modify the room name field.
                let nameIndex = try #require(fields.firstIndex { $0.variable == "muc#roomconfig_roomname" })
                let newName = "room-\(UUID().uuidString.prefix(8))"
                fields[nameIndex].values = [newName]

                // Submit modified config.
                try await harness.environment.chatService.submitRoomConfig(
                    jidString: roomJID.description,
                    fields: fields,
                    accountID: alice.accountID
                )

                // Re-fetch and verify.
                let updatedFields = try await harness.environment.chatService.getRoomConfig(
                    jidString: roomJID.description,
                    accountID: alice.accountID
                )
                let updatedName = try #require(updatedFields.first { $0.variable == "muc#roomconfig_roomname" })
                #expect(updatedName.values == [newName])
            }
        }

        @Test @MainActor func `Service processes invite decline`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                // Alice invites bob.
                try await harness.environment.chatService.inviteUser(
                    jidString: bobJID.description,
                    toRoomJIDString: roomJID.description,
                    reason: "Please join",
                    accountID: alice.accountID
                )

                // Bob receives the invite event.
                _ = try await bob.waitForEvent { event in
                    if case let .roomInviteReceived(invite) = event, invite.room == roomJID { return true }
                    return false
                }

                // Wait for the pending invite to appear in service state.
                try await bob.waitForCondition {
                    harness.environment.chatService.pendingInvites.contains { $0.roomJIDString == roomJID.description }
                }

                let pending = try #require(
                    harness.environment.chatService.pendingInvites.first { $0.roomJIDString == roomJID.description }
                )

                // Bob declines. Direct invite → local-only removal.
                try await harness.environment.chatService.declineInvite(
                    pending,
                    reason: "No thanks",
                    accountID: bob.accountID
                )

                // Verify pending invite was removed.
                try await bob.waitForCondition {
                    !harness.environment.chatService.pendingInvites.contains { $0.roomJIDString == roomJID.description }
                }
            }
        }
    }
}
