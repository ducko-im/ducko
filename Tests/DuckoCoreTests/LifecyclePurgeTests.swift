import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// End-to-end coverage for the lifecycle teardown paths that bypass the services' `.disconnected` handlers:
/// `AccountService.disconnect(accountID:)` cancels the account's event task before `.disconnected` is delivered,
/// and `deleteAccount(_:)` never routes through it. Both must still purge every per-account cache via the
/// `purgeAccount` wiring. Driving a real `AppEnvironment` (rather than a hand-mirrored `wireServices`) keeps the
/// fixture honest as services are added to production wiring.
enum LifecyclePurgeTests {
    struct Purge {
        private func makePresence(show: XMPPPresence.Show? = nil, status: String? = nil) -> XMPPPresence {
            var presence = XMPPPresence(type: nil)
            presence.show = show
            presence.status = status
            return presence
        }

        /// Builds a real `AppEnvironment`, creates one account, and seeds every per-account cache the lifecycle
        /// purge should clear (roster, presence, bookmarks, avatar, file offers), asserting each is populated.
        @MainActor
        private func makeSeededEnvironment() async throws -> (env: AppEnvironment, accountID: UUID) {
            let store = MockPersistenceStore()
            let env = AppEnvironment(
                store: store,
                transcripts: MockTranscriptStore(),
                credentialStore: NullCredentialStore()
            )

            let accountID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let peerJID = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            let peerFull = try #require(FullJID(bareJID: peerJID, resourcePart: "res"))
            let peerFrom = JID.full(peerFull)
            let room = try #require(BareJID.parse("room@conference.example.com"))
            let inviter = try #require(BareJID.parse("inviter@example.com"))

            let fixture = RosterServiceFixture(store: store, service: env.rosterService)
            await fixture.deliver(
                .snapshot([RosterItem(jid: peerJID, name: "Bob", subscription: .both, ask: false, groups: [])]),
                accountID: accountID
            )
            await env.presenceService.handleEvent(
                .presenceUpdated(from: peerFrom, presence: makePresence(show: .away, status: "Busy")),
                accountID: accountID
            )
            await env.chatService.handleEvent(
                .roomInviteReceived(RoomInvite(room: room, from: .bare(inviter))),
                accountID: accountID
            )
            env.bookmarksService.setBookmarksForTesting([RoomBookmark(jidString: "room@conference.example.com")], accountID: accountID)
            env.avatarService.setOwnAvatarHashForTesting("hash", accountID: accountID)
            env.fileTransferService.handleJingleEvent(
                .jingleFileTransferReceived(JingleFileOffer(offerID: "file-offer", sid: "file-sid", from: peerFull, fileName: "f.bin", fileSize: 1)),
                accountID: accountID
            )
            env.fileTransferService.handleJingleEvent(
                .oobIQOfferReceived(OOBIQOffer(offerID: "link-offer", id: "link-id", from: peerFrom, url: "https://example.com/f.bin", desc: nil)),
                accountID: accountID
            )

            #expect(!env.rosterService.groups.isEmpty)
            #expect(!env.presenceService.contactPresences.isEmpty)
            #expect(!env.presenceService.contactStatusMessages.isEmpty)
            #expect(!env.chatService.pendingInvites.isEmpty)
            #expect(!env.bookmarksService.bookmarks.isEmpty)
            #expect(env.avatarService.ownAvatarHash(for: accountID) != nil)
            #expect(env.fileTransferService.viewIncomingOffers.count == 2)

            return (env, accountID)
        }

        /// A disconnect keeps the account's contacts listed, shown offline, and a delete removes them.
        @MainActor
        private func expectAllPurged(_ env: AppEnvironment, _ accountID: UUID, contactsListed: Bool) {
            #expect(env.rosterService.groups.isEmpty == !contactsListed)
            #expect(env.presenceService.contactPresences.isEmpty)
            #expect(env.presenceService.contactStatusMessages.isEmpty)
            #expect(env.chatService.pendingInvites.isEmpty)
            #expect(env.bookmarksService.bookmarks.isEmpty)
            #expect(env.avatarService.ownAvatarHash(for: accountID) == nil)
            #expect(env.fileTransferService.viewIncomingOffers.isEmpty)
        }

        @Test
        @MainActor
        func `disconnect purges every per-account cache on the path that bypasses the event handler`() async throws {
            let (env, accountID) = try await makeSeededEnvironment()

            await env.accountService.disconnect(accountID: accountID)

            expectAllPurged(env, accountID, contactsListed: true)
        }

        @Test
        @MainActor
        func `deleteAccount purges every per-account cache`() async throws {
            let (env, accountID) = try await makeSeededEnvironment()

            try await env.accountService.deleteAccount(accountID)

            expectAllPurged(env, accountID, contactsListed: false)
        }
    }
}
