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

                _ = try await bob.waitForEvent { event in
                    if case let .roomMessageReceived(m) = event, m.body == originalBody { return true }
                    return false
                }

                let newBody = "msg-\(UUID().uuidString.prefix(8))"
                let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalID])
                try await aliceMUC.sendMessage(to: roomJID, body: newBody, additionalElements: [replace])

                _ = try await bob.waitForEvent { event in
                    if case let .messageCorrected(origID, correctedBody, _, from: _, messageType: _) = event,
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
                    if case let .roomMessageReceived(m) = event, m.body == body { return m }
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
                    if case let .roomMessageReceived(m) = event, m.body == body { return m }
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
    }
}
