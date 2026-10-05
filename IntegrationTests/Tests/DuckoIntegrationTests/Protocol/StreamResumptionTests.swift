import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct StreamResumptionTests {
        @Test @MainActor func `A room keeps working across a dropped and resumed connection`() async throws {
            try await TestHarness.withHarness { harness in
                // The relay forwards to port 5222 at alice's domain, where the test server takes client connections.
                // Cutting it drops alice as a lost network does.
                let relay = ConnectionRelay()
                harness.addCleanup { await relay.stop() }
                let server = try harness.jid(for: TestCredentials.alice).domainPart
                let relayPort = try await relay.start(forwardingTo: server, port: 5222)
                try await harness.setUp(
                    accounts: ["alice": TestCredentials.alice, "bob": TestCredentials.bob],
                    endpoints: ["alice": (host: "127.0.0.1", port: Int(relayPort))]
                )
                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let chat = harness.environment.chatService

                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let (bobMUC, _) = try await harness.joinRoom(roomJID, as: "bob", using: "bob")
                let aliceSeesBob: @MainActor () async -> Bool = {
                    chat.participants(forRoomJIDString: roomJID.description, accountID: alice.accountID).contains { $0.nickname == "bob" }
                }
                try await alice.waitForCondition(aliceSeesBob)

                let duringDrop = "during-drop-\(UUID().uuidString.prefix(8))"
                let afterResume = "after-resume-\(UUID().uuidString.prefix(8))"
                // Everything bob sees of the room from here to the echo of his last message, which follows the resume
                // and the three waits after it.
                let untilLastEcho = TestTimeout.streamResume + TestTimeout.event * 3
                async let bobEvents = bob.collectEvents(until: { Self.isRoomMessage($0, body: afterResume) }, timeout: untilLastEcho)
                async let disconnected = alice.waitForEvent(matching: Self.isDisconnected)
                async let resumed = alice.waitForEvent(matching: Self.isStreamResumed, timeout: TestTimeout.streamResume)

                await relay.dropConnections()
                _ = try await disconnected
                try await bobMUC.sendMessage(to: roomJID, body: duringDrop)
                _ = try await resumed

                // The message the server replayed is stored, although it arrived ahead of `.streamResumed`.
                try await alice.waitForCondition {
                    let conversations = await (try? chat.fetchAllConversations()) ?? []
                    guard let room = conversations.first(where: { $0.jid == roomJID && $0.accountID == alice.accountID }) else { return false }
                    return await chat.loadMessages(for: room.id).contains { $0.body == duringDrop }
                }
                try await alice.waitForCondition(aliceSeesBob)

                async let received = alice.waitForEvent(matching: { Self.isRoomMessage($0, body: afterResume) })
                try await bobMUC.sendMessage(to: roomJID, body: afterResume)
                _ = try await received

                // Alice stayed in the room throughout: bob saw her neither leave nor join.
                let aliceChanges = try await bobEvents.filter { Self.isArrivalOrDeparture($0, of: "alice", in: roomJID) }
                #expect(aliceChanges.isEmpty)
            }
        }

        private static func isDisconnected(_ event: XMPPEvent) -> Bool {
            if case .disconnected = event { return true }
            return false
        }

        private static func isStreamResumed(_ event: XMPPEvent) -> Bool {
            if case .streamResumed = event { return true }
            return false
        }

        private static func isArrivalOrDeparture(_ event: XMPPEvent, of nickname: String, in roomJID: BareJID) -> Bool {
            if case let .roomOccupantJoined(room, occupant) = event { return room == roomJID && occupant.nickname == nickname }
            if case let .roomOccupantLeft(room, occupant, _) = event { return room == roomJID && occupant.nickname == nickname }
            return false
        }

        private static func isRoomMessage(_ event: XMPPEvent, body: String) -> Bool {
            if case let .roomMessageReceived(message) = event { return message.body == body }
            return false
        }
    }
}
