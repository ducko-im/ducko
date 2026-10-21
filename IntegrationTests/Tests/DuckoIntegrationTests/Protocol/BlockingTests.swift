import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct BlockingTests {
        // MARK: - Protocol Layer

        @Test @MainActor func `Alice blocks Bob and sees contactBlocked`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try JID.bare(harness.jid(for: TestCredentials.bob))
                let blocking = try await harness.module(BlockingModule.self, for: "alice")
                try await Self.ensureBobUnblocked(alice: alice, blocking: blocking, bobJID: bobJID)

                Self.registerUnblockCleanup(blocking: blocking, bobJID: bobJID, harness: harness)
                try await blocking.blockContact(jid: bobJID)

                _ = try await alice.waitForEvent { event in
                    if case let .contactBlocked(jid) = event, jid == bobJID { return true }
                    return false
                }
            }
        }

        @Test(.timeLimit(.minutes(1))) @MainActor func `Block list reloads after reconnect`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try JID.bare(harness.jid(for: TestCredentials.bob))
                let blocking = try await harness.module(BlockingModule.self, for: "alice")
                try await Self.ensureBobUnblocked(alice: alice, blocking: blocking, bobJID: bobJID)

                // This test reconnects alice, which creates a new BlockingModule.
                // Route cleanup through RosterService so it always resolves the
                // current client rather than capturing the pre-reconnect module.
                harness.addCleanup {
                    try? await harness.environment.rosterService.unblockContact(
                        jidString: bobJID.description, accountID: alice.accountID
                    )
                }
                try await blocking.blockContact(jid: bobJID)

                _ = try await alice.waitForEvent { event in
                    if case let .contactBlocked(jid) = event, jid == bobJID { return true }
                    return false
                }

                // Reconnect to trigger BlockingModule.handleConnect → .blockListLoaded.
                // Explicit password is required because disconnect zeroes
                // passwords[accountID] and the harness never calls savePassword.
                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")
                try await harness.environment.accountService.connect(accountID: alice.accountID, password: TestCredentials.alice.password)

                _ = try await alice.waitForEvent(
                    matching: { event in
                        if case let .blockListLoaded(jids) = event, jids.contains(bobJID) { return true }
                        return false
                    },
                    timeout: TestTimeout.connect
                )
            }
        }

        @Test @MainActor func `Alice unblocks Bob and sees contactUnblocked`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try JID.bare(harness.jid(for: TestCredentials.bob))
                let blocking = try await harness.module(BlockingModule.self, for: "alice")
                try await Self.ensureBobUnblocked(alice: alice, blocking: blocking, bobJID: bobJID)

                Self.registerUnblockCleanup(blocking: blocking, bobJID: bobJID, harness: harness)
                try await blocking.blockContact(jid: bobJID)
                _ = try await alice.waitForEvent { event in
                    if case let .contactBlocked(jid) = event, jid == bobJID { return true }
                    return false
                }

                try await blocking.unblockContact(jid: bobJID)
                _ = try await alice.waitForEvent { event in
                    if case let .contactUnblocked(jid) = event, jid == bobJID { return true }
                    return false
                }
            }
        }

        // MARK: - Service Layer

        @Test @MainActor func `Service blockContact then unblockContact round-trips`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try JID.bare(harness.jid(for: TestCredentials.bob))
                let blocking = try await harness.module(BlockingModule.self, for: "alice")
                try await Self.ensureBobUnblocked(alice: alice, blocking: blocking, bobJID: bobJID)

                Self.registerUnblockCleanup(blocking: blocking, bobJID: bobJID, harness: harness)
                try await harness.environment.rosterService.blockContact(jidString: bobJID.description, accountID: alice.accountID)
                try await alice.waitForCondition({ blocking.blockedJIDs.contains(bobJID) })

                try await harness.environment.rosterService.unblockContact(jidString: bobJID.description, accountID: alice.accountID)
                try await alice.waitForCondition({ !blocking.blockedJIDs.contains(bobJID) })
            }
        }

        @Test @MainActor func `A device-only entry shows in the block list and leaves the contact unblocked`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let bobJID = try harness.jid(for: TestCredentials.bob)
                let device = "\(bobJID)/ducko-blocking-test"
                let rosterService = harness.environment.rosterService
                harness.addCleanup {
                    try? await rosterService.unblockContact(jidString: device, accountID: alice.accountID)
                }

                try await rosterService.blockContact(jidString: device, accountID: alice.accountID)
                try await alice.waitForCondition({ rosterService.blockList(for: alice.accountID).contains { $0.jidString == device } })
                #expect(rosterService.contact(jidString: bobJID.description, accountID: alice.accountID)?.isBlocked != true)

                try await rosterService.unblockContact(jidString: device, accountID: alice.accountID)
                try await alice.waitForCondition({ !rosterService.blockList(for: alice.accountID).contains { $0.jidString == device } })
            }
        }

        // MARK: - Helpers

        /// If `.blockListLoaded` placed bob in the block list, unblock him
        /// before the test mutates state so each test starts from a clean
        /// baseline. Gives BlockingModule.handleConnect a brief poll window
        /// because `.blockListLoaded` may fire before setUp's initial roster response
        /// await registers, consuming the event without inspecting it.
        private static func ensureBobUnblocked(
            alice: ConnectedAccount, blocking: BlockingModule, bobJID: JID
        ) async throws {
            try? await alice.waitForCondition(
                { blocking.blockedJIDs.contains(bobJID) },
                timeout: .seconds(2)
            )
            if blocking.blockedJIDs.contains(bobJID) {
                try await blocking.unblockContact(jid: bobJID)
                _ = try await alice.waitForEvent { event in
                    if case let .contactUnblocked(jid) = event, jid == bobJID { return true }
                    return false
                }
            }
        }

        /// Registers a best-effort unblock so a crashed test still leaves the
        /// server clean. Registered BEFORE the blocking mutation so an early
        /// failure still triggers teardown via the LIFO cleanup chain.
        @MainActor
        private static func registerUnblockCleanup(
            blocking: BlockingModule, bobJID: JID, harness: TestHarness
        ) {
            harness.addCleanup {
                try? await blocking.unblockContact(jid: bobJID)
            }
        }
    }
}
