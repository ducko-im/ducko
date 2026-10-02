import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let testAccountID = UUID()
private let contactJID1 = BareJID(localPart: "alice", domainPart: "example.com")!
private let contactJID2 = BareJID(localPart: "bob", domainPart: "example.com")!
private let contactJID3 = BareJID(localPart: "carol", domainPart: "example.com")!

private func makeStore() -> MockPersistenceStore {
    MockPersistenceStore()
}

private func makeRosterItem(
    jid: BareJID,
    name: String? = nil,
    subscription: RosterItem.Subscription = .both,
    ask: Bool = false,
    groups: [String] = []
) -> RosterItem {
    RosterItem(jid: jid, name: name, subscription: subscription, ask: ask, groups: groups)
}

private func makeContact(
    jid: BareJID,
    name: String? = nil,
    localAlias: String? = nil,
    groups: [String] = []
) -> Contact {
    Contact(
        id: UUID(),
        accountID: testAccountID,
        jid: jid,
        name: name,
        localAlias: localAlias,
        subscription: .both,
        groups: groups,
        isBlocked: false,
        createdAt: Date()
    )
}

// MARK: - Tests

enum RosterServiceTests {
    struct RosterLoaded {
        @Test
        @MainActor
        func `Roster loaded event persists contacts to store`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice"),
                makeRosterItem(jid: contactJID2, name: "Bob")
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 2)
        }

        @Test
        @MainActor
        func `Roster loaded builds correct groups`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"]),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Work"])
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Work")
        }

        @Test
        @MainActor
        func `Contacts without groups go into Ungrouped`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice"),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"])
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Ungrouped")
            #expect(service.groups[1].contacts.count == 1)
            #expect(service.groups[1].contacts[0].jid == contactJID1)
        }

        @Test
        @MainActor
        func `Existing contacts preserve localAlias on roster reload`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Pre-populate store with a contact that has a local alias
            let existing = makeContact(jid: contactJID1, name: "Alice", localAlias: "My Friend")
            try await store.upsertContact(existing)

            let items = [makeRosterItem(jid: contactJID1, name: "Alice Updated")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].name == "Alice Updated")
            #expect(contacts[0].localAlias == "My Friend")
        }

        @Test
        @MainActor
        func `Contacts removed from roster are deleted from store`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Pre-populate with two contacts
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))
            try await store.upsertContact(makeContact(jid: contactJID2, name: "Bob"))

            // Roster reload only contains Alice
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].jid == contactJID1)
        }
    }

    struct RosterItemChanged {
        @Test
        @MainActor
        func `New roster item creates contact`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let item = makeRosterItem(jid: contactJID1, name: "Alice")
            await fixture.deliver(.delta(item), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].jid == contactJID1)
            #expect(contacts[0].name == "Alice")
        }

        @Test
        @MainActor
        func `Updated roster item updates contact fields`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Create initial contact
            let item1 = makeRosterItem(jid: contactJID1, name: "Alice")
            await fixture.deliver(.delta(item1), accountID: testAccountID)

            // Update name
            let item2 = makeRosterItem(jid: contactJID1, name: "Alice Smith")
            await fixture.deliver(.delta(item2), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.count == 1)
            #expect(contacts[0].name == "Alice Smith")
        }

        @Test
        @MainActor
        func `Roster item with subscription=remove deletes contact`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Create initial contact
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))

            let item = makeRosterItem(jid: contactJID1, subscription: .remove)
            await fixture.deliver(.delta(item), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts.isEmpty)
        }

        @Test
        @MainActor
        func `Roster item change refreshes the cached groups`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // An add must publish into the stored `groups` cache, not just the store.
            await fixture.deliver(.delta(makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"])), accountID: testAccountID)
            #expect(service.groups.first?.contacts.first?.jid == contactJID1)

            // A subsequent remove must refresh the cache, leaving no contacts.
            await fixture.deliver(.delta(makeRosterItem(jid: contactJID1, subscription: .remove)), accountID: testAccountID)
            #expect(service.groups.flatMap(\.contacts).isEmpty)
        }
    }

    struct GroupBuilding {
        @Test
        @MainActor
        func `Groups sorted alphabetically, Ungrouped last`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Work"]),
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"]),
                makeRosterItem(jid: contactJID3, name: "Carol")
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            #expect(service.groups.count == 3)
            #expect(service.groups[0].name == "Friends")
            #expect(service.groups[1].name == "Work")
            #expect(service.groups[2].name == "Ungrouped")
        }

        @Test
        @MainActor
        func `Contacts sorted by display name within groups`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"]),
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"])
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            #expect(service.groups.count == 1)
            #expect(service.groups[0].contacts[0].name == "Alice")
            #expect(service.groups[0].contacts[1].name == "Bob")
        }

        @Test
        @MainActor
        func `Contact in multiple groups appears in each`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [
                makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends", "Work"])
            ]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            #expect(service.groups.count == 2)
            #expect(service.groups[0].contacts[0].jid == contactJID1)
            #expect(service.groups[1].contacts[0].jid == contactJID1)
        }
    }

    struct StringBasedMethods {
        @Test
        @MainActor
        func `addContact(jidString:) throws notConnected without account service`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterCommandError.self) {
                try await service.addContact(jidString: "alice@example.com", name: "Alice", groups: ["Friends"], accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `addContact(jidString:) throws invalidJID for empty string`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.addContact(jidString: "", name: nil, groups: [], accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `removeContact(jidString:) throws notConnected without account service`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Load a roster so groups are populated
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            await #expect(throws: RosterCommandError.self) {
                try await service.removeContact(jidString: contactJID1.description, accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `removeContact(jidString:) throws invalidJID for empty string`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Empty string fails BareJID.parse — should throw invalidJID
            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.removeContact(jidString: "", accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `approveSubscription(jidString:) throws notConnected without account service`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.approveSubscription(jidString: "alice@example.com", accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `denySubscription(jidString:) throws notConnected without account service`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.denySubscription(jidString: "alice@example.com", accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `requestSubscription(jidString:) throws notConnected without account service`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.requestSubscription(jidString: "alice@example.com", accountID: testAccountID)
            }
        }

        @Test
        @MainActor
        func `requestSubscription(jidString:) throws invalidJID for empty string`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await #expect(throws: RosterService.RosterServiceError.self) {
                try await service.requestSubscription(jidString: "", accountID: testAccountID)
            }
        }
    }

    struct AccountScopedLookup {
        @Test
        @MainActor
        func `contact(jidString:accountID:) resolves the requested account when the JID is on two`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            // Same bare JID present on both accounts with different roster names.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice-A")]), accountID: accountA)
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice-B")]), accountID: accountB)

            #expect(service.contact(jidString: contactJID1.description, accountID: accountA)?.name == "Alice-A")
            #expect(service.contact(jidString: contactJID1.description, accountID: accountB)?.name == "Alice-B")
        }

        @Test
        @MainActor
        func `contact(jidString:accountID:) returns nil for a JID on a different account`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: accountA)

            #expect(service.contact(jidString: contactJID1.description, accountID: accountB) == nil)
        }
    }

    struct DuplicatedJIDPredicate {
        @Test
        @MainActor
        func `accountIDs(forBareJID:) dedups a multi-group contact and counts each account once`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            // Same contact in two groups under A must still count A exactly once.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends", "Work"])]), accountID: accountA)
            #expect(service.accountIDs(forBareJID: contactJID1.description) == [accountA])

            // The same JID also on B makes it duplicated across two accounts.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice-B")]), accountID: accountB)
            #expect(service.accountIDs(forBareJID: contactJID1.description) == [accountA, accountB])

            // A JID on no account resolves to the empty set.
            #expect(service.accountIDs(forBareJID: "nobody@example.com").isEmpty)
        }
    }

    struct GroupMerging {
        @Test
        @MainActor
        func `same group name across accounts merges into one section keyed by name`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            // Both contacts are ungrouped, so each account contributes an "Ungrouped" group.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: accountA)
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID2, name: "Bob")]), accountID: accountB)

            let ungrouped = service.groups.filter { $0.name == ContactGroup.ungroupedName }
            #expect(ungrouped.count == 1)

            let merged = try #require(ungrouped.first)
            // A single name-based id post-merge — a safe `ForEach`/`onlineCounts` key.
            #expect(merged.id == ContactGroup.ungroupedName)
            #expect(merged.contacts.count == 2)
            // Both accounts' contacts are present, distinguishable by accountID.
            #expect(Set(merged.contacts.map(\.accountID)) == [accountA, accountB])
        }

        @Test
        @MainActor
        func `onlineCounts for a merged group totals contacts across accounts`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: accountA)
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID2, name: "Bob")]), accountID: accountB)

            let merged = try #require(service.groups.first { $0.name == ContactGroup.ungroupedName })
            let counts = ContactListSizing.onlineCounts(
                groupID: merged.id,
                unfilteredRoster: service.groups,
                displayedContacts: merged.contacts
            ) { $0.jid == contactJID1 }

            #expect(counts.total == 2)
            #expect(counts.online == 1)
        }

        @Test
        @MainActor
        func `merged sections sort alphabetically with Ungrouped last across accounts`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            // Account A contributes "Work"; account B contributes "Friends" and an ungrouped contact.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Work"])]), accountID: accountA)
            await fixture.deliver(.snapshot([
                makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"]),
                makeRosterItem(jid: contactJID3, name: "Carol")
            ]), accountID: accountB)

            #expect(service.groups.map(\.name) == ["Friends", "Work", ContactGroup.ungroupedName])
        }

        @Test
        @MainActor
        func `contacts interleave alphabetically across accounts within a merged group`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            // Bob on A, Alice on B, both in "Friends" — the merged section must sort Alice before Bob,
            // not cluster per account in insertion order.
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID2, name: "Bob", groups: ["Friends"])]), accountID: accountA)
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice", groups: ["Friends"])]), accountID: accountB)

            let friends = try #require(service.groups.first { $0.name == "Friends" })
            #expect(friends.contacts.map(\.name) == ["Alice", "Bob"])
        }
    }

    struct Disconnect {
        @Test
        @MainActor
        func `Disconnect event clears the cached groups for the account`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: testAccountID)
            #expect(!service.groups.isEmpty)

            service.receiveRosterEvent(.disconnected(.requested), accountID: testAccountID)
            #expect(service.groups.isEmpty)
        }

        @Test
        @MainActor
        func `Disconnect clears only the disconnected account's groups`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            let accountA = UUID()
            let accountB = UUID()

            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: accountA)
            await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID2, name: "Bob")]), accountID: accountB)
            #expect(service.groups.flatMap(\.contacts).count == 2)

            // Tearing down account A must leave account B's contacts in the merged cache.
            service.receiveRosterEvent(.disconnected(.requested), accountID: accountA)

            let remaining = service.groups.flatMap(\.contacts)
            #expect(remaining.count == 1)
            #expect(remaining.first?.jid == contactJID2)
        }

        @Test
        @MainActor
        func `A roster load racing a purge does not repopulate the cleared groups`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Seed a contact so a completed load would publish a non-empty merge.
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await store.installFetchContactsGate(entered: entered, release: release)

            let load = Task { @MainActor in try await service.loadContacts(for: testAccountID) }

            // Park the load at its store read, then tear the account down so the generation counter bumps.
            await entered.wait()
            service.purgeAccount(testAccountID)

            // Release the read; the resumed load must observe the bumped generation and bail without publishing.
            await release.signal()
            try await load.value

            #expect(service.groups.isEmpty)
        }

        @Test
        @MainActor
        func `A roster-loaded event racing a purge neither repopulates groups nor mutates the store`() async {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await store.installRosterApplyGate(entered: entered, release: release)

            let load = Task { @MainActor in
                await fixture.deliver(.snapshot([makeRosterItem(jid: contactJID1, name: "Alice")]), accountID: testAccountID)
            }

            // Park the handler at its store read, then tear the account down.
            await entered.wait()
            service.purgeAccount(testAccountID)

            await release.signal()
            await load.value

            // The pre-persistence guard must bail before the upsert, so the store stays empty too — not just the cache.
            #expect(service.groups.isEmpty)
            #expect(await store.contacts.isEmpty)
        }

        @Test
        @MainActor
        func `A roster-item-changed event racing a purge neither repopulates groups nor adds the contact`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            // Pre-seed Alice (ungated) so we can prove the racing change neither publishes nor writes Bob.
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await store.installRosterApplyGate(entered: entered, release: release)

            let load = Task { @MainActor in
                await fixture.deliver(.delta(makeRosterItem(jid: contactJID2, name: "Bob")), accountID: testAccountID)
            }

            // Park at the first store read, tear the account down, then release. The pre-persistence guard
            // must bail before the upsert (and before the second fetch), so Bob is never written.
            await entered.wait()
            service.purgeAccount(testAccountID)
            await release.signal()
            await load.value

            #expect(service.groups.isEmpty)
            #expect(await !store.contacts.contains { $0.jid == contactJID2 })
        }

        @Test
        @MainActor
        func `updateLastSeen racing a purge neither republishes groups nor writes lastSeen`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service
            // Seed the contact updateLastSeen would touch (it only acts on an existing contact).
            try await store.upsertContact(makeContact(jid: contactJID1, name: "Alice"))

            let entered = AsyncSemaphore()
            let release = AsyncSemaphore()
            await store.installFetchContactsGate(entered: entered, release: release)

            let task = Task { @MainActor in
                await service.updateLastSeen(jid: contactJID1, date: Date(), accountID: testAccountID)
            }

            await entered.wait()
            service.purgeAccount(testAccountID)
            await release.signal()
            await task.value

            // The generation guard must bail before the upsert, so lastSeen is never written and groups stay cleared.
            #expect(service.groups.isEmpty)
            let stored = await store.contacts.first { $0.jid == contactJID1 }
            #expect(stored?.lastSeen == nil)
        }
    }

    struct ContactDisplayName {
        @Test
        func `displayName prefers localAlias over name`() {
            let contact = makeContact(jid: contactJID1, name: "Alice", localAlias: "Ally")
            #expect(contact.displayName == "Ally")
        }

        @Test
        func `displayName falls back to name when no localAlias`() {
            let contact = makeContact(jid: contactJID1, name: "Alice")
            #expect(contact.displayName == "Alice")
        }

        @Test
        func `displayName falls back to JID when no name or alias`() {
            let contact = makeContact(jid: contactJID1)
            #expect(contact.displayName == contactJID1.description)
        }
    }

    struct RenameContact {
        @Test
        @MainActor
        func `Rename updates localAlias in store and rebuilds groups`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            // Create initial contact via roster load
            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            let contact = try #require(contacts.first)

            try await service.renameContact(contact, newAlias: "Ally", accountID: testAccountID)

            let updated = try await store.fetchContacts(for: testAccountID)
            #expect(updated[0].localAlias == "Ally")
        }
    }

    struct UpdateLastSeen {
        @Test
        @MainActor
        func `updateLastSeen persists date for matching contact`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let date = Date()
            await service.updateLastSeen(jid: contactJID1, date: date, accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].lastSeen == date)
        }

        @Test
        @MainActor
        func `updateLastSeen is no-op for unknown JID`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [makeRosterItem(jid: contactJID1, name: "Alice")]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let unknownJID = try #require(BareJID(localPart: "unknown", domainPart: "example.com"))
            await service.updateLastSeen(jid: unknownJID, date: Date(), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].lastSeen == nil)
        }
    }

    struct AskField {
        @Test
        @MainActor
        func `Roster item with ask=true produces contact with ask=subscribe`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [makeRosterItem(jid: contactJID1, name: "Alice", ask: true)]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].ask == "subscribe")
        }

        @Test
        @MainActor
        func `Roster item with ask=false produces contact with nil ask`() async throws {
            let store = makeStore()
            let fixture = RosterServiceFixture(store: store)
            let service = fixture.service

            let items = [makeRosterItem(jid: contactJID1, name: "Alice", ask: false)]
            await fixture.deliver(.snapshot(items), accountID: testAccountID)

            let contacts = try await store.fetchContacts(for: testAccountID)
            #expect(contacts[0].ask == nil)
        }
    }
}
