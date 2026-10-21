import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Covers the lifecycle-purge wiring that lives at the `AppEnvironment` seam.
enum AppEnvironmentPurgeTests {
    @MainActor
    private static func makeEnvironment(store: MockPersistenceStore) -> AppEnvironment {
        AppEnvironment(store: store, transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(), omemoStore: MockOMEMOStore())
    }

    struct DispatchCancellation {
        @Test
        @MainActor
        func `user-initiated disconnect cancels a queued roster event so it can't repopulate the cleared cache`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let accountID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let peer = try #require(BareJID(localPart: "bob", domainPart: "example.com"))
            // Seed a contact so the roster event, if it ran, would publish a non-empty merge.
            try await store.upsertContact(Contact(id: UUID(), accountID: accountID, jid: peer, subscription: .both, groups: [], isBlocked: false, createdAt: Date()))

            // Queue a roster-loaded fan-out task through the real dispatch closure, then disconnect before it
            // runs. `disconnect` has no client to await here, so its synchronous prefix cancels the task first.
            let fixture = RosterServiceFixture(store: store, service: env.rosterService)
            try await fixture.prepare(accountID: accountID)
            env.accountService.onEvent?(.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([RosterItem(jid: peer, name: "Bob", subscription: .both)]), version: nil)), accountID)
            await env.accountService.disconnect(accountID: accountID)

            // Let the cancelled task attempt to run; it must bail at its top-level `Task.isCancelled` check
            // rather than fetch + republish the just-purged cache.
            for _ in 0 ..< 20 {
                await Task.yield()
            }
            #expect(env.rosterService.groups.isEmpty)
        }
    }

    struct AvatarIsolation {
        @Test
        @MainActor
        func `disconnect purges only the disconnected account's avatar hash`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let aliceID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let bobID = try await env.accountService.createAccount(jidString: "bob@example.com")
            env.avatarService.setOwnAvatarHashForTesting("hash-alice", accountID: aliceID)
            env.avatarService.setOwnAvatarHashForTesting("hash-bob", accountID: bobID)

            await env.accountService.disconnect(accountID: aliceID)

            // Per-account isolation: Alice's hash is gone, Bob's survives.
            #expect(env.avatarService.ownAvatarHash(for: aliceID) == nil)
            #expect(env.avatarService.ownAvatarHash(for: bobID) == "hash-bob")
        }

        @Test
        @MainActor
        func `deleteAccount purges only the deleted account's avatar hash`() async throws {
            let store = MockPersistenceStore()
            let env = AppEnvironmentPurgeTests.makeEnvironment(store: store)

            let aliceID = try await env.accountService.createAccount(jidString: "alice@example.com")
            let bobID = try await env.accountService.createAccount(jidString: "bob@example.com")
            env.avatarService.setOwnAvatarHashForTesting("hash-alice", accountID: aliceID)
            env.avatarService.setOwnAvatarHashForTesting("hash-bob", accountID: bobID)

            try await env.accountService.deleteAccount(aliceID)

            #expect(env.avatarService.ownAvatarHash(for: aliceID) == nil)
            #expect(env.avatarService.ownAvatarHash(for: bobID) == "hash-bob")
        }
    }
}

@MainActor
extension AppEnvironmentPurgeTests {
    @Test(arguments: [false, true])
    static func `composed teardown clears the feature caches for only its account, and a delete also clears what stays shown offline`(delete: Bool) async throws {
        let store = MockPersistenceStore()
        let env = makeEnvironment(store: store)
        let first = try await seedCaches(env, store: store, name: "first")
        let second = try await seedCaches(env, store: store, name: "second")
        await assertCaches(env, account: first, present: true, shown: true)
        await assertCaches(env, account: second, present: true, shown: true)
        if delete { try await env.accountService.deleteAccount(first.id) } else { await env.accountService.disconnect(accountID: first.id) }
        await assertCaches(env, account: first, present: false, shown: !delete)
        await assertCaches(env, account: second, present: true, shown: true)
        await env.shutdown(within: .seconds(2))
    }

    @Test
    static func `disconnect cancels suspended roster dispatch before it can restore cache or store state`() async throws {
        let store = MockPersistenceStore()
        let env = makeEnvironment(store: store)
        let id = try await env.accountService.createAccount(jidString: "alice@example.com")
        let peer = try #require(BareJID.parse("bob@example.com"))
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        let fixture = RosterServiceFixture(store: store, service: env.rosterService)
        try await fixture.prepare(accountID: id)
        await store.installRosterApplyGate(entered: entered, release: release)
        env.accountService.onEvent?(.rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([RosterItem(jid: peer, name: "Bob", subscription: .both)]), version: nil)), id)
        let arrival = try await boundedOutcome { await entered.wait() }
        guard arrival != nil else {
            await release.signal()
            await env.shutdown(within: .seconds(2))
            Issue.record("Roster dispatch never reached the controlled store read")
            return
        }
        await env.accountService.disconnect(accountID: id)
        await release.signal()
        await env.shutdown(within: .seconds(2))
        #expect(env.rosterService.groups.isEmpty)
        #expect(await store.contacts.isEmpty)
        #expect(env.bookmarksService.bookmarks.isEmpty)
        #expect(env.avatarService.ownAvatarHash(for: id) == nil)
    }

    private static func seedCaches(_ env: AppEnvironment, store: MockPersistenceStore, name: String) async throws -> (id: UUID, peer: BareJID) {
        let id = try await env.accountService.createAccount(jidString: "\(name)@example.com")
        let peer = try #require(BareJID.parse("\(name)-peer@example.com"))
        try await store.upsertContact(Contact(id: UUID(), accountID: id, jid: peer, subscription: .both, groups: [], isBlocked: false, createdAt: Date()))
        try await env.rosterService.loadContacts(for: id)
        await env.presenceService.handleEvent(.presenceSubscriptionRequest(from: peer), accountID: id)
        await env.chatService.handleEvent(.roomInviteReceived(RoomInvite(room: peer, from: .bare(peer))), accountID: id)
        env.chatService.learnChatStateUse(of: .contact(peer), uses: false, accountID: id)
        env.bookmarksService.setBookmarksForTesting([RoomBookmark(jidString: peer.description)], accountID: id)
        env.avatarService.setOwnAvatarHashForTesting(name, accountID: id)
        env.profileService.setOwnProfileForTesting(ProfileInfo(), accountID: id)
        await env.omemoService.installAccountJIDForTesting("\(name)@example.com", accountID: id.uuidString)
        await env.omemoService.mergeSeenDevices(
            [42: SeenDeviceRecord(deviceID: 42, lastClassification: .healthy, staleStreak: 0, hasObservedHealthy: true)],
            accountID: id.uuidString
        )
        return (id, peer)
    }

    /// `shown` covers what a disconnect keeps and a delete drops: the account's contact and your profile, which open
    /// chats and the Contacts header still show; the OMEMO seen-device classifications; and which peers send no chat
    /// states.
    private static func assertCaches(_ env: AppEnvironment, account: (id: UUID, peer: BareJID), present: Bool, shown: Bool) async {
        #expect((env.rosterService.contact(jidString: account.peer.description, accountID: account.id) != nil) == present)
        #expect((env.rosterService.knownContact(jidString: account.peer.description, accountID: account.id) != nil) == shown)
        #expect(env.presenceService.pendingSubscriptionRequests.contains(account.peer) == present)
        #expect(env.chatService.pendingInvites.contains { $0.accountID == account.id } == present)
        #expect(env.bookmarksService.bookmarks.contains { $0.jidString == account.peer.description } == present)
        #expect((env.avatarService.ownAvatarHash(for: account.id) != nil) == present)
        #expect((env.profileService.ownProfile(for: account.id) != nil) == shown)
        #expect(await env.omemoService.loadSeenDevices(accountID: account.id.uuidString).isEmpty == !shown)
        #expect(env.chatService.sendsChatStates(to: .contact(account.peer), accountID: account.id) == !shown)
    }
}
