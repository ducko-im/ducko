import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct OMEMOTests {
        // MARK: - Protocol Layer

        @Test(.timeLimit(.minutes(1))) @MainActor func `OMEMO bundle publish lists Alice's own device`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice], loadOMEMOFixtures: true)
                Self.enableTOFU(harness: harness)

                let aliceJID = try harness.jid(for: TestCredentials.alice)
                let aliceOMEMO = try await harness.module(OMEMOModule.self, for: "alice")

                // OMEMOModule.handleConnect ran synchronously inside the
                // connect chain before setUp returned, so the module-level
                // identity data is ready immediately. Avoid the service-level
                // `ownDeviceInfo` path — that's behind an async persistence
                // task that can lag behind connect.
                let ownIdentity = try #require(aliceOMEMO.ownIdentityData)
                let deviceID = ownIdentity.deviceID

                // Prosody's mod_pep doesn't send +notify back to the publisher's
                // own resources, so assert via a fresh PEP items IQ get instead
                // of waiting for `.pepItemsPublished`. PEP device lists are
                // append-only — assert containment, not count.
                let devices = try await aliceOMEMO.fetchDeviceList(for: aliceJID)
                #expect(devices.contains(deviceID))
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `OMEMO session establishes between Alice and Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpAliceBobWithTOFU(harness: harness)
                let ctx = try await Self.primeBobForEncryption(harness: harness)
                let body = "omemo-msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: ctx.bobJID, body: body, accountID: ctx.alice.accountID)

                _ = try await ctx.alice.waitForEvent(
                    matching: { event in
                        if case let .omemoSessionEstablished(jid, _, _, _) = event, jid == ctx.bobJID { return true }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )

                _ = try await ctx.bob.waitForEvent(
                    matching: { event in
                        if case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event,
                           decrypted.message.body == body {
                            return true
                        }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `Encrypted OMEMO message body round-trips to Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpAliceBobWithTOFU(harness: harness)
                let ctx = try await Self.primeBobForEncryption(harness: harness)
                let body = "omemo-msg-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: ctx.bobJID, body: body, accountID: ctx.alice.accountID)

                let decryptedBody = try await ctx.bob.waitForEvent(
                    extracting: { event in
                        if case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event,
                           decrypted.message.body == body {
                            return decrypted.message.body
                        }
                        return nil
                    },
                    timeout: TestTimeout.omemoSession
                )
                #expect(decryptedBody == body)
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `OMEMO multi-recipient send reaches Bob and Carol`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob,
                    "carol": TestCredentials.carol
                ], loadOMEMOFixtures: true)
                Self.enableTOFU(harness: harness)

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let carol = try #require(harness.accounts["carol"])
                let aliceOMEMO = try await harness.module(OMEMOModule.self, for: "alice")
                let bobJID = try harness.jid(for: TestCredentials.bob)
                let carolJID = try harness.jid(for: TestCredentials.carol)

                try await Self.primePeerForEncryption(harness: harness, aliceOMEMO: aliceOMEMO, aliceID: alice.accountID, peerLabel: "bob", peerJID: bobJID)
                try await Self.primePeerForEncryption(harness: harness, aliceOMEMO: aliceOMEMO, aliceID: alice.accountID, peerLabel: "carol", peerJID: carolJID)

                let bobBody = "omemo-bob-\(UUID().uuidString.prefix(8))"
                let carolBody = "omemo-carol-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: bobJID, body: bobBody, accountID: alice.accountID)
                try await harness.environment.chatService.sendMessage(to: carolJID, body: carolBody, accountID: alice.accountID)

                _ = try await bob.waitForEvent(
                    matching: { event in
                        if case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event,
                           decrypted.message.body == bobBody {
                            return true
                        }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )
                _ = try await carol.waitForEvent(
                    matching: { event in
                        if case let .omemoEncryptedMessageReceived(_, .decrypted(decrypted)) = event,
                           decrypted.message.body == carolBody {
                            return true
                        }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )
            }
        }

        // MARK: - Service Layer

        @Test(.timeLimit(.minutes(2))) @MainActor func `Service encrypted send persists the message on Bob's side`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpAliceBobWithTOFU(harness: harness)
                let ctx = try await Self.primeBobForEncryption(harness: harness)
                let aliceJID = try harness.jid(for: TestCredentials.alice)

                let body = "omemo-service-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: harness.jid(for: TestCredentials.bob), body: body, accountID: ctx.alice.accountID)

                _ = try await ctx.bob.waitForEvent(
                    matching: { event in
                        if case .omemoEncryptedMessageReceived = event { return true }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )

                let bobConversation = try await harness.environment.chatService.openConversation(for: aliceJID, accountID: ctx.bob.accountID)

                // OMEMOService persists via a detached Task after the event
                // fires, so wait for the transcript to catch up before asserting.
                try await ctx.bob.waitForCondition {
                    let messages = await harness.environment.chatService.loadMessages(for: bobConversation.id)
                    guard let last = messages.last else { return false }
                    return last.isEncrypted && last.body == body
                }
                let messages = await harness.environment.chatService.loadMessages(for: bobConversation.id)
                let persisted = try #require(messages.last)
                #expect(persisted.isEncrypted)
                #expect(persisted.body == body)
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `Encrypted send targets Bob's locked full JID`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpAliceBobWithTOFU(harness: harness)
                let ctx = try await Self.primeBobForEncryption(harness: harness)
                let aliceJID = try harness.jid(for: TestCredentials.alice)
                let bobJID = ctx.bobJID

                // Bob messages Alice first (plaintext) so Alice's ChatService locks Bob's bound resource (RFC 6121 §5.1).
                let lockBody = "lock-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: aliceJID, body: lockBody, accountID: ctx.bob.accountID)

                // learnResourceLock runs in the same handler invocation immediately before persistAndNotify, so a
                // persisted inbound from Bob implies the lock is set. Wait for that before Alice replies.
                let aliceBobConversation = try await harness.environment.chatService.openConversation(for: bobJID, accountID: ctx.alice.accountID)
                try await ctx.alice.waitForCondition {
                    let messages = await harness.environment.chatService.loadMessages(for: aliceBobConversation.id)
                    return messages.contains { !$0.isOutgoing && $0.body == lockBody }
                }

                // Alice's encrypted reply must be addressed to Bob's full (locked) JID. Prosody preserves the
                // `to` it was sent, so a resource-qualified `to` on the encrypted stanza Bob receives proves the
                // lock drove the routing — while OMEMO device resolution stays on the bare JID (covered by the
                // round-trip tests above).
                let body = "omemo-locked-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: bobJID, body: body, accountID: ctx.alice.accountID)

                let receivedTo = try await ctx.bob.waitForEvent(
                    extracting: { event -> JID? in
                        guard case let .messageReceived(message) = event,
                              message.element.child(named: "encrypted", namespace: XMPPNamespaces.omemo) != nil,
                              message.to?.bareJID == bobJID else { return nil }
                        return message.to
                    },
                    timeout: TestTimeout.omemoSession
                )

                let isFullJID = if case .full = receivedTo { true } else { false }
                #expect(isFullJID)
            }
        }

        @Test(.timeLimit(.minutes(2))) @MainActor func `Service trust device transitions through trust levels`() async throws {
            try await TestHarness.withHarness { harness in
                try await Self.setUpAliceBobWithTOFU(harness: harness)
                let ctx = try await Self.primeBobForEncryption(harness: harness)

                let body = "omemo-trust-\(UUID().uuidString.prefix(8))"
                try await harness.environment.chatService.sendMessage(to: ctx.bobJID, body: body, accountID: ctx.alice.accountID)

                // Wait for the session so fingerprints are populated organically.
                _ = try await ctx.bob.waitForEvent(
                    matching: { event in
                        if case .omemoEncryptedMessageReceived = event { return true }
                        return false
                    },
                    timeout: TestTimeout.omemoSession
                )

                let initial = await harness.environment.omemoService.deviceInfoList(for: ctx.bobJID.description, accountID: ctx.alice.accountID)
                let seeded = try #require(initial.first(where: { !$0.fingerprint.isEmpty }))
                try await Self.assertTrustTransitions(
                    harness: harness, accountID: ctx.alice.accountID,
                    peerJID: ctx.bobJID.description, seeded: seeded
                )
            }
        }

        /// Drives trustDevice → untrustDevice → verifyDevice on the OMEMOService
        /// and asserts `deviceInfoList` reflects each transition. Scoped strictly
        /// to the seeded device ID so PEP's append-only semantics don't leak
        /// unrelated devices into the assertion.
        @MainActor
        private static func assertTrustTransitions(
            harness: TestHarness, accountID: UUID,
            peerJID: String, seeded: OMEMODeviceInfo
        ) async throws {
            try await harness.environment.omemoService.trustDevice(
                accountID: accountID, peerJID: peerJID,
                deviceID: seeded.deviceID, fingerprint: seeded.fingerprint
            )
            var list = await harness.environment.omemoService.deviceInfoList(for: peerJID, accountID: accountID)
            var entry = try #require(list.first { $0.deviceID == seeded.deviceID })
            #expect(entry.trustLevel == .trusted)

            try await harness.environment.omemoService.untrustDevice(
                accountID: accountID, peerJID: peerJID, deviceID: seeded.deviceID
            )
            list = await harness.environment.omemoService.deviceInfoList(for: peerJID, accountID: accountID)
            entry = try #require(list.first { $0.deviceID == seeded.deviceID })
            #expect(entry.trustLevel == .untrusted)

            try await harness.environment.omemoService.verifyDevice(
                accountID: accountID, peerJID: peerJID,
                deviceID: seeded.deviceID, fingerprint: seeded.fingerprint
            )
            list = await harness.environment.omemoService.deviceInfoList(for: peerJID, accountID: accountID)
            entry = try #require(list.first { $0.deviceID == seeded.deviceID })
            #expect(entry.trustLevel == .verified)
        }

        @Test @MainActor func `Service ownFingerprint returns a stable hex string`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice], loadOMEMOFixtures: true)

                let alice = try #require(harness.accounts["alice"])

                // OMEMOService.handleConnected persists the identity on a
                // detached Task that outlives setUp's initial roster response wait, so
                // wait until the store is populated.
                try await alice.waitForCondition {
                    await harness.environment.omemoService.ownFingerprint(accountID: alice.accountID) != nil
                }
                let firstFingerprint = try #require(await harness.environment.omemoService.ownFingerprint(accountID: alice.accountID))
                let secondFingerprint = try #require(await harness.environment.omemoService.ownFingerprint(accountID: alice.accountID))
                #expect(!firstFingerprint.isEmpty)
                #expect(firstFingerprint == secondFingerprint)
            }
        }

        // MARK: - Helpers

        /// Connects alice and bob and enables TOFU for the harness scope. Every
        /// Alice→Bob encryption test needs both steps in the same order.
        @MainActor
        private static func setUpAliceBobWithTOFU(harness: TestHarness) async throws {
            try await harness.setUp(accounts: [
                "alice": TestCredentials.alice,
                "bob": TestCredentials.bob
            ], loadOMEMOFixtures: true)
            enableTOFU(harness: harness)
        }

        /// Test-local context produced by `primeBobForEncryption`.
        @MainActor
        private struct EncryptionContext {
            let alice: ConnectedAccount
            let bob: ConnectedAccount
            let bobJID: BareJID
        }

        /// Seeds alice's OMEMOService with bob's undecided device records
        /// (TOFU promotes them to encryptable), opens the bob conversation, and
        /// flips encryption on. Returns the context every encrypted-send test
        /// needs; the test just adds its specific body and assertions.
        @MainActor
        private static func primeBobForEncryption(harness: TestHarness) async throws -> EncryptionContext {
            let alice = try #require(harness.accounts["alice"])
            let bob = try #require(harness.accounts["bob"])
            let aliceOMEMO = try await harness.module(OMEMOModule.self, for: "alice")
            let bobJID = try harness.jid(for: TestCredentials.bob)

            try await primePeerForEncryption(
                harness: harness, aliceOMEMO: aliceOMEMO,
                aliceID: alice.accountID, peerLabel: "bob", peerJID: bobJID
            )
            return EncryptionContext(alice: alice, bob: bob, bobJID: bobJID)
        }

        /// Refreshes alice's view of a peer's PEP device list, waits for the
        /// fresh deviceID to land in alice's OMEMOStore (so TOFU picks it up),
        /// opens the conversation, and flips encryption on.
        @MainActor
        private static func primePeerForEncryption(
            harness: TestHarness, aliceOMEMO: OMEMOModule, aliceID: UUID,
            peerLabel: String, peerJID: BareJID
        ) async throws {
            _ = try await aliceOMEMO.fetchDeviceList(for: peerJID, forceRefresh: true)
            try await awaitPeerDeviceInStore(
                harness: harness, peerLabel: peerLabel,
                accountID: aliceID, peerJID: peerJID
            )
            let conversation = try await harness.environment.chatService.openConversation(for: peerJID, accountID: aliceID)
            try await harness.environment.chatService.setEncryptionEnabled(true, for: conversation.id, accountID: aliceID)
        }

        /// Polls alice's OMEMOStore until the peer's fresh-this-session deviceID
        /// (as reported by the peer's own OMEMOModule) is present.
        ///
        /// Alice's view of peer devices is populated asynchronously: the peer
        /// publishes in `handleConnect`, alice's server relays a PEP +notify,
        /// and `OMEMOService.handleDeviceListReceived` persists via a detached
        /// task. Without this wait, encrypt can race the +notify and omit the
        /// peer's current device — the stanza goes out with no key for the
        /// online resource, and decryption falls through to `notForThisDevice`.
        @MainActor
        private static func awaitPeerDeviceInStore(
            harness: TestHarness, peerLabel: String,
            accountID: UUID, peerJID: BareJID,
            timeout: Duration = TestTimeout.omemoSession
        ) async throws {
            let peer = try #require(harness.accounts[peerLabel])
            let peerOMEMO = try await harness.module(OMEMOModule.self, for: peerLabel)
            let peerDeviceID = try #require(peerOMEMO.ownIdentityData?.deviceID)

            try await peer.waitForCondition({
                let infos = await harness.environment.omemoService.deviceInfoList(
                    for: peerJID.description, accountID: accountID
                )
                return infos.contains(where: { $0.deviceID == peerDeviceID })
            }, timeout: timeout)
        }

        /// Enables trust-on-first-use for the current harness scope and restores
        /// the prior value at teardown. Without TOFU, `.undecided` peer devices
        /// yield no encryption targets and no session can be driven.
        @MainActor
        private static func enableTOFU(harness: TestHarness) {
            let prior = OMEMOPreferences.shared.trustOnFirstUse
            OMEMOPreferences.shared.trustOnFirstUse = true
            harness.addCleanup {
                await MainActor.run {
                    OMEMOPreferences.shared.trustOnFirstUse = prior
                }
            }
        }
    }
}
