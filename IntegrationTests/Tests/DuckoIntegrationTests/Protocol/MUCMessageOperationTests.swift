import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MUCMessageOperationTests {
        /// Extracts the room-assigned stanza-id from a message element.
        private static func roomStanzaID(from element: DuckoXMPP.XMLElement, roomJID: BareJID) -> String? {
            element.children(named: "stanza-id")
                .first(where: { $0.namespace == XMPPNamespaces.stanzaID && $0.attribute("by") == roomJID.description })
                .flatMap { $0.attribute("id") }
        }

        // MARK: - Protocol Layer

        @Test @MainActor func `MUC message correction replaces original`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let alice = try #require(harness.accounts["alice"])
                let aliceClient = try #require(harness.environment.accountService.client(for: alice.accountID))
                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                let originalBody = "msg-\(UUID().uuidString.prefix(8))"
                let originalID = aliceClient.generateID()
                try await aliceMUC.sendMessage(to: roomJID, body: originalBody, id: originalID)

                _ = try await bob.waitForEvent { $0.isRoomMessage(body: originalBody) }

                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalID])
                try await aliceMUC.sendMessage(to: roomJID, body: newBody, additionalElements: [replace])

                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, correctedBody, _, from: _, messageType: _, roomAuthor: _) = event,
                       origID == originalID, correctedBody == newBody {
                        return true
                    }
                    return false
                }
            }
        }

        @Test @MainActor func `Moderator retracts a message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let (bobMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                // Bob sends a message.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: body)

                // Alice captures the room-assigned stanza-id.
                let receivedMessage = try await alice.waitForEvent(extracting: { event in
                    if case let .roomMessageReceived(m, _) = event, m.body == body { return m }
                    return nil
                })

                // Extract stanza-id assigned by the room (filter by `by` == room JID).
                let stanzaID = try #require(Self.roomStanzaID(from: receivedMessage.element, roomJID: roomJID))

                // Alice (moderator/owner) retracts bob's message.
                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")
                try await aliceMUC.moderateMessage(room: roomJID, stanzaID: stanzaID, reason: "inappropriate")

                // Extract non-nil reasons; a nil moderationReason would fail the
                // `#expect(reason == "inappropriate")` assertion anyway, so gating
                // the extract on `reason?` keeps T as plain `String`.
                let reason = try await bob.waitForEvent(extracting: { event -> String? in
                    if case let .messageModerated(origID, _, room, moderationReason?) = event,
                       origID == stanzaID, room == roomJID {
                        return moderationReason
                    }
                    return nil
                })
                #expect(reason == "inappropriate")
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service moderates a message`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let (bobMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                // Bob sends a message.
                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: body)

                // Alice captures the room-assigned stanza-id.
                let receivedMessage = try await alice.waitForEvent(extracting: { event in
                    if case let .roomMessageReceived(m, _) = event, m.body == body { return m }
                    return nil
                })

                let stanzaID = try #require(Self.roomStanzaID(from: receivedMessage.element, roomJID: roomJID))

                // Alice moderates via service. Joining stored the room, which the cache holds once loaded.
                try await harness.environment.chatService.loadConversations(for: alice.accountID)
                let room = try #require(harness.environment.chatService.openConversations.first {
                    $0.jid == roomJID && $0.accountID == alice.accountID && $0.type == .groupchat
                })
                try await harness.environment.chatService.moderateMessage(
                    serverID: stanzaID,
                    in: room,
                    reason: "inappropriate",
                    accountID: alice.accountID
                )

                // Extract non-nil reasons; a nil moderationReason would fail the
                // `#expect(reason == "inappropriate")` assertion anyway, so gating
                // the extract on `reason?` keeps T as plain `String`.
                let reason = try await bob.waitForEvent(extracting: { event -> String? in
                    if case let .messageModerated(origID, _, room, moderationReason?) = event,
                       origID == stanzaID, room == roomJID {
                        return moderationReason
                    }
                    return nil
                })
                #expect(reason == "inappropriate")
            }
        }

        @Test @MainActor func `Service applies an occupant's own room correction and retraction`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")
                let chatService = harness.environment.chatService
                let aliceRoom = try await harness.storedRoom(roomJID, for: "alice")
                let bobRoom = try await harness.storedRoom(roomJID, for: "bob")

                let body = "msg-\(UUID().uuidString.prefix(8))"
                try await chatService.sendGroupMessage(to: roomJID, body: body, accountID: bob.accountID)

                // The room's echo records its stanza-id on Bob's row, which a room retraction names.
                let bobRow = try await harness.storedMessage(in: bobRoom.id, for: "bob") {
                    $0.isOutgoing && $0.body == body && $0.serverID != nil
                }
                let aliceRow = try await harness.storedMessage(in: aliceRoom.id, for: "alice") { !$0.isOutgoing && $0.body == body }
                #expect(aliceRow.fromJID == "bob")
                #expect(aliceRow.roomSender?.occupantID != nil)
                #expect(aliceRow.stanzaID == bobRow.stanzaID)
                #expect(aliceRow.serverID == bobRow.serverID)

                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                try await chatService.sendCorrection(of: bobRow, newBody: newBody, in: bobRoom, accountID: bob.accountID)
                let corrected = try await harness.storedMessage(in: aliceRoom.id, for: "alice") { $0.id == aliceRow.id && $0.isEdited }
                #expect(corrected.body == newBody)

                try await chatService.retractMessage(bobRow, in: bobRoom, accountID: bob.accountID)
                _ = try await harness.storedMessage(in: aliceRoom.id, for: "alice") { $0.id == aliceRow.id && $0.isRetracted }
            }
        }

        @Test @MainActor func `Service ignores amendments from another occupant under the author's nickname`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob,
                    "carol": TestCredentials.carol
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let (bobMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")
                let aliceRoom = try await harness.storedRoom(roomJID, for: "alice")

                let originalBody = "msg-\(UUID().uuidString.prefix(8))"
                let original = try await Self.send(originalBody, to: roomJID, as: "bob", storedIn: aliceRoom.id, harness: harness)
                let bobOccupantID = try #require(original.row.roomSender?.occupantID)

                try await bobMUC.leaveRoom(roomJID)
                _ = try await alice.waitForEvent { $0.isDeparture(of: "bob", from: roomJID) }

                // Carol takes Bob's nickname and sends a message of her own, which she then amends as a control.
                let (carolMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "carol")
                let controlBody = "msg-\(UUID().uuidString.prefix(8))"
                let control = try await Self.send(controlBody, to: roomJID, as: "carol", storedIn: aliceRoom.id, harness: harness)
                #expect(control.row.fromJID == "bob")
                let carolOccupantID = try #require(control.row.roomSender?.occupantID)
                #expect(carolOccupantID != bobOccupantID)

                // Carol's correction and retraction of Bob's message, each followed by the same amendment of her own
                // message. The room relays them to Alice in the order sent.
                let forgedBody = "msg-\(UUID().uuidString.prefix(8))"
                try await carolMUC.sendMessage(to: roomJID, body: forgedBody, additionalElements: [Self.replaceElement(original.id)])
                let controlCorrection = "msg-\(UUID().uuidString.prefix(8))"
                try await carolMUC.sendMessage(to: roomJID, body: controlCorrection, additionalElements: [Self.replaceElement(control.id)])
                _ = try await harness.storedMessage(in: aliceRoom.id, for: "alice") {
                    $0.id == control.row.id && $0.isEdited && $0.body == controlCorrection
                }

                try await carolMUC.sendMessage(to: roomJID, body: Self.retractionFallback, additionalElements: Self.retractionElements(original.serverID))
                try await carolMUC.sendMessage(to: roomJID, body: Self.retractionFallback, additionalElements: Self.retractionElements(control.serverID))
                _ = try await harness.storedMessage(in: aliceRoom.id, for: "alice") { $0.id == control.row.id && $0.isRetracted }

                // Alice's client received both forgeries, each under Bob's nickname with Carol's occupant id.
                let events = try await alice.collectEvents(until: { Self.isAmendment($0, naming: control.serverID, under: "bob", by: carolOccupantID) })
                #expect(events.contains { Self.isAmendment($0, naming: original.id, under: "bob", by: carolOccupantID) })
                #expect(events.contains { Self.isAmendment($0, naming: original.serverID, under: "bob", by: carolOccupantID) })

                let messages = await harness.environment.chatService.loadMessages(for: aliceRoom.id)
                let unchanged = try #require(messages.first { $0.id == original.row.id })
                #expect(unchanged.body == originalBody)
                #expect(!unchanged.isEdited)
                #expect(!unchanged.isRetracted)
                #expect(!messages.contains { $0.body == forgedBody })
            }
        }

        // MARK: - Room Messages

        /// A room message as its sender's echo and Alice's stored row show it.
        private struct SentRoomMessage {
            /// The message's own id, which a correction names.
            let id: String
            /// The stanza-id the room assigned to it, which a retraction names.
            let serverID: String
            /// Alice's row of it.
            let row: ChatMessage
        }

        /// Sends `body` to `roomJID` as the account under `label`, and returns it once Alice has stored it in
        /// `conversationID`, where both of its ids name it.
        @MainActor
        private static func send(
            _ body: String, to roomJID: BareJID, as label: String, storedIn conversationID: UUID, harness: TestHarness
        ) async throws -> SentRoomMessage {
            let sender = try #require(harness.accounts[label])
            let mucModule = try await harness.module(MUCModule.self, for: label)
            let client = try #require(harness.environment.accountService.client(for: sender.accountID))
            let id = client.generateID()
            try await mucModule.sendMessage(to: roomJID, body: body, id: id)
            let echo = try await sender.waitForEvent(extracting: { event in
                if case let .roomMessageReceived(m, _) = event, m.body == body { return m }
                return nil
            })
            let serverID = try #require(roomStanzaID(from: echo.element, roomJID: roomJID))
            let row = try await harness.storedMessage(in: conversationID, for: "alice") { !$0.isOutgoing && $0.body == body }
            #expect(row.stanzaID == id)
            #expect(row.serverID == serverID)
            return SentRoomMessage(id: id, serverID: serverID, row: row)
        }

        /// Whether `event` is a room correction or retraction naming `id`, sent under `nickname` with `occupantID`.
        private static func isAmendment(_ event: XMPPEvent, naming id: String, under nickname: String, by occupantID: String) -> Bool {
            if case let .messageCorrected(origID, _, _, from: .full(sender), messageType: _, roomAuthor: author?) = event {
                return origID == id && sender.resourcePart == nickname && author.occupantID == occupantID
            }
            if case let .messageRetracted(origID, from: .full(sender), messageType: _, roomAuthor: author?) = event {
                return origID == id && sender.resourcePart == nickname && author.occupantID == occupantID
            }
            return false
        }

        // MARK: - Amendment Elements

        /// The fallback body of a retraction, for clients without XEP-0424.
        private static let retractionFallback = "This person attempted to retract a previous message, but it's unsupported by your client."

        /// A correction's `<replace/>` of the message sent as `id` (XEP-0308).
        private static func replaceElement(_ id: String) -> DuckoXMPP.XMLElement {
            DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": id])
        }

        /// A room retraction's `<retract/>` of the message the room assigned `serverID` to, with its fallback marker (XEP-0424).
        private static func retractionElements(_ serverID: String) -> [DuckoXMPP.XMLElement] {
            [
                DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": serverID]),
                FallbackIndication(for: XMPPNamespaces.messageRetract).element
            ]
        }
    }
}
