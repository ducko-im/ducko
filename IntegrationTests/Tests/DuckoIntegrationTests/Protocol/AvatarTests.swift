import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.ProtocolLayer {
    struct AvatarTests {
        // MARK: - Service Layer

        /// Precondition (documented in `TestCredentials`): alice and bob have a
        /// pre-existing mutual roster subscription so PEP+ notifications flow.
        @Test(.timeLimit(.minutes(1))) @MainActor func `Publishing Alice's avatar changes ownAvatarHash and reaches Bob`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let aliceJID = try harness.jid(for: TestCredentials.alice)

                // Fetch Alice's current avatar directly rather than reading the cached own-hash, so cleanup
                // restores the avatar that's actually on the server regardless of what's cached locally.
                let originalAvatar = await harness.environment.avatarService.fetchAvatar(for: aliceJID, accountID: alice.accountID)

                harness.addCleanup {
                    if let originalAvatar {
                        try? await harness.environment.avatarService.publishAvatar(
                            imageData: originalAvatar.data,
                            accountID: alice.accountID
                        )
                    } else {
                        try? await harness.environment.avatarService.removeAvatar(accountID: alice.accountID)
                    }
                }

                let published = try await harness.environment.avatarService.publishAvatar(
                    imageData: AvatarFixtures.minimalPNG(), accountID: alice.accountID
                )
                let expectedHash = published.hash

                // Prosody's mod_pep doesn't fan `+notify` events back to the
                // publisher's own resources, so alice's own-account publish is
                // verified locally: `publishAvatar` sets `ownAvatarHash` only
                // after the avatar-data and avatar-metadata PEP publish IQs
                // both succeed.
                #expect(harness.environment.avatarService.ownAvatarHash(for: alice.accountID) == expectedHash)

                // Bob sees either the PEP+ metadata publish or the XEP-0153
                // vCard fallback — both count as cross-account visibility.
                // Match on the newly-published hash specifically so a
                // connect-time sync of Alice's prior avatar can't satisfy it.
                _ = try await bob.waitForEvent { event in
                    if case let .pepItemsPublished(from, node, items) = event,
                       from == aliceJID, node == XMPPNamespaces.avatarMetadata,
                       items.contains(where: { $0.id == expectedHash }) {
                        return true
                    }
                    if case let .vcardAvatarHashReceived(from, hash) = event,
                       from.bareJID == aliceJID, hash == expectedHash {
                        return true
                    }
                    return false
                }
            }
        }

        /// Precondition (documented in `TestCredentials`): alice and bob have a
        /// pre-existing mutual roster subscription so alice has presence-access
        /// to bob's avatar PEP nodes (`urn:xmpp:avatar:data`/`:metadata` default
        /// to `access_model=presence`).
        @Test(.timeLimit(.minutes(1))) @MainActor func `Alice fetches Bob's avatar after Bob publishes`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: [
                    "alice": TestCredentials.alice,
                    "bob": TestCredentials.bob
                ])

                let alice = try #require(harness.accounts["alice"])
                let bob = try #require(harness.accounts["bob"])
                let bobJID = try harness.jid(for: TestCredentials.bob)

                let priorBobAvatar = await harness.environment.avatarService.fetchAvatar(for: bobJID, accountID: bob.accountID)

                harness.addCleanup {
                    if let priorBobAvatar {
                        try? await harness.environment.avatarService.publishAvatar(
                            imageData: priorBobAvatar.data,
                            accountID: bob.accountID
                        )
                    } else {
                        try? await harness.environment.avatarService.removeAvatar(accountID: bob.accountID)
                    }
                }

                let published = try await harness.environment.avatarService.publishAvatar(
                    imageData: AvatarFixtures.minimalPNG(), accountID: bob.accountID
                )

                let result = try #require(await harness.environment.avatarService.fetchAvatar(for: bobJID, accountID: alice.accountID))
                #expect(result.data == published.data)
                #expect(result.hash == published.hash)
            }
        }

        // MARK: - Fixture

        /// Pinned literal guards the cross-account hashing path against regressions:
        /// the live tests above compare hashes that `sha1Hex` computed on both sides,
        /// which is self-referential.
        @Test func `Minimal PNG fixture hashes to pinned SHA-1`() {
            #expect(sha1Hex(Array(AvatarFixtures.minimalPNG())) == AvatarFixtures.minimalPNGSHA1)
        }
    }
}
