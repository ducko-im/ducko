import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct MUCMAMTests {
        @Test @MainActor func `Room archive returns sent messages`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let bob = try #require(harness.accounts["bob"])
                _ = try await harness.joinRoom(roomJID, as: "bob", using: "bob")

                let aliceMUC = try await harness.module(MUCModule.self, for: "alice")

                // Send 3 messages with UUID bodies.
                var sentBodies: [String] = []
                for _ in 0 ..< 3 {
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    sentBodies.append(body)
                    try await aliceMUC.sendMessage(to: roomJID, body: body)

                    // Wait for bob to receive each before sending next (ensures server persistence).
                    _ = try await bob.waitForEvent { $0.isRoomMessage(body: body) }
                }

                // Query the room archive.
                let aliceMAM = try await harness.module(MAMModule.self, for: "alice")
                let (messages, _) = try await aliceMAM.queryMessages(MAMModule.Query(to: roomJID))

                // Filter by UUID bodies (archive may contain join/subject notifications).
                let matchedBodies = messages.compactMap(\.forwarded.message.body).filter { sentBodies.contains($0) }
                #expect(matchedBodies.count == 3)
                for body in sentBodies {
                    #expect(matchedBodies.contains(body))
                }
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `Catch-up shows a message sent under the user's nickname by another occupant as theirs`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob,
                    "carol": TestCredentials.carol
                ])

                // Bob stays in the room while Alice is away, so the room outlives her leaving it.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let carol = try #require(harness.accounts["carol"])
                let (bobMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")
                let chatService = harness.environment.chatService

                // Alice's room keeps the occupant id the room gave her, which lets a catch-up read the room's archive
                // before she joins it again. She does not rejoin it here, since the harness turns auto-join off.
                let aliceRoom = try await harness.storedRoom(roomJID, for: "alice") { $0.roomOccupantID != nil }
                let ownOccupantID = try #require(aliceRoom.roomOccupantID)

                let bobBody = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: bobBody)
                _ = try await harness.storedMessage(in: aliceRoom.id, for: "alice") { $0.body == bobBody }

                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")
                _ = try await bob.waitForEvent { $0.isDeparture(of: "alice", from: roomJID) }

                // Carol takes Alice's nickname while she is away.
                let (carolMUC, _) = try await harness.joinRoom(roomJID, as: "alice", using: "carol")
                let carolBody = "msg-\(UUID().uuidString.prefix(8))"
                try await carolMUC.sendMessage(to: roomJID, body: carolBody)
                _ = try await bob.waitForEvent { $0.isRoomMessage(body: carolBody) }

                try await Self.reconnect(alice, credential: TestCredentials.alice, in: harness)
                // The catch-up runs after the roster loads, reading the account's archive before the room's.
                let carolRow = try await harness.storedMessage(in: aliceRoom.id, for: "alice", timeout: TestTimeout.connect) { $0.body == carolBody }
                #expect(!carolRow.isOutgoing)
                #expect(carolRow.fromJID == "alice")
                let carolOccupantID = try #require(carolRow.roomSender?.occupantID)
                #expect(carolOccupantID != ownOccupantID)
                let caughtUp = await chatService.loadMessages(for: aliceRoom.id)
                #expect(caughtUp.map(\.body).sorted() == [bobBody, carolBody].sorted())

                // A second catch-up starts where the first one ended, so it reads Carol's message again. Bob's message,
                // sent after it, shows when that catch-up has read past it.
                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")
                let laterBody = "msg-\(UUID().uuidString.prefix(8))"
                try await bobMUC.sendMessage(to: roomJID, body: laterBody)
                _ = try await carol.waitForEvent { $0.isRoomMessage(body: laterBody) }

                try await Self.reconnect(alice, credential: TestCredentials.alice, in: harness)
                let laterRow = try await harness.storedMessage(in: aliceRoom.id, for: "alice", timeout: TestTimeout.connect) { $0.body == laterBody }
                let recaught = await chatService.loadMessages(for: aliceRoom.id)
                #expect(Set(recaught.map(\.id)) == Set(caughtUp.map(\.id) + [laterRow.id]))
                #expect(recaught.first { $0.id == carolRow.id }?.isOutgoing == false)
            }
        }

        /// Connects `account` again, which catches up on the archives once the roster has loaded.
        @MainActor
        private static func reconnect(_ account: ConnectedAccount, credential: TestCredentials.Credential, in harness: TestHarness) async throws {
            // The harness never saves the password, and a disconnect forgets it.
            try await harness.environment.accountService.connect(accountID: account.accountID, password: credential.password)
            _ = try await account.waitForEvent(
                matching: { event in
                    if case let .rosterUpdated(update) = event, update.isInitialResponse { return true }
                    return false
                },
                timeout: TestTimeout.connect
            )
        }
    }
}
