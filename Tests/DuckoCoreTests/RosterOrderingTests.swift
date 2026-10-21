import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct RosterOrderingTests {
    @Test
    func `authoritative empty roster removes cached contacts`() async throws {
        let store = MockPersistenceStore()
        let fixture = RosterServiceFixture(store: store)
        let service = fixture.service
        let accountID = UUID()
        let jid = try #require(BareJID.parse("bob@example.com"))
        await fixture.deliver(.snapshot([RosterItem(jid: jid, subscription: .both)]), accountID: accountID)

        await fixture.deliver(.snapshot([]), accountID: accountID)

        #expect(try await store.fetchContacts(for: accountID).isEmpty)
        #expect(service.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func `delayed alias update cannot restore removed identity`(readd: Bool) async throws {
        let store = MockPersistenceStore()
        let fixture = RosterServiceFixture(store: store)
        let service = fixture.service
        let accountID = UUID()
        let jid = try #require(BareJID.parse("bob@example.com"))
        let original = Contact(id: UUID(), accountID: accountID, jid: jid, subscription: .both, groups: [], isBlocked: false, createdAt: Date())
        try await store.upsertContact(original)
        try await store.deleteContact(original.id)
        let replacement = Contact(id: UUID(), accountID: accountID, jid: jid, name: "New contact", subscription: .none, groups: [], isBlocked: false, createdAt: Date())
        if readd { try await store.upsertContact(replacement) }

        try await service.renameContact(original, newAlias: "Old alias", accountID: accountID)

        let contacts = try await store.fetchContacts(for: accountID)
        #expect(!contacts.contains { $0.id == original.id })
        #expect(contacts.count == (readd ? 1 : 0))
        #expect(contacts.first?.localAlias == nil)
    }
}

extension RosterOrderingTests {
    @Test(arguments: ["alias", "last-seen", "block", "block-list"], [false, true])
    func `suspended metadata write cannot change a removed identity`(field: String, readd: Bool) async throws {
        let store = MockPersistenceStore()
        let fixture = RosterServiceFixture(store: store)
        let accountID = UUID()
        let jid = try #require(BareJID.parse("bob@example.com"))
        await fixture.deliver(.snapshot([RosterItem(jid: jid, name: "Original")]), accountID: accountID)
        let original = try #require(try await store.fetchContacts(for: accountID).first)
        let entered = AsyncSemaphore()
        let release = AsyncSemaphore()
        await store.installContactWriteGate(entered: entered, release: release)
        let mutation = Task {
            switch field {
            case "alias": try await fixture.service.renameContact(original, newAlias: "Old alias", accountID: accountID)
            case "last-seen": await fixture.service.updateLastSeen(jid: jid, date: Date(), accountID: accountID)
            case "block": await fixture.service.handleEvent(.contactBlocked(.bare(jid)), accountID: accountID)
            case "block-list": await fixture.service.handleEvent(.blockListLoaded([.bare(jid)]), accountID: accountID)
            default: Issue.record("Unknown fixture")
            }
        }
        try #require(try await boundedOutcome { await entered.wait() } != nil)
        await fixture.deliver(.snapshot([]), accountID: accountID)
        if readd { await fixture.deliver(.snapshot([RosterItem(jid: jid, name: "Replacement")]), accountID: accountID) }
        await release.signal()
        try await mutation.value
        let contacts = try await store.fetchContacts(for: accountID)
        #expect(contacts.count == (readd ? 1 : 0))
        #expect(!contacts.contains { $0.id == original.id })
        if let contact = contacts.first {
            #expect(contact.name == "Replacement")
            #expect(contact.localAlias == nil)
            #expect(contact.lastSeen == nil)
            #expect(!contact.isBlocked)
        }
        fixture.service.purgeAccount(accountID)
        for task in fixture.service.takePendingTasks() {
            await task.value
        }
    }

    @Test
    func `slow account does not block another account and stale reload cannot replace a newer snapshot`() async throws {
        let store = MockPersistenceStore()
        let fixture = RosterServiceFixture(store: store)
        let first = UUID(), second = UUID()
        let bob = try #require(BareJID.parse("bob@example.com"))
        let carol = try #require(BareJID.parse("carol@example.com"))
        await fixture.deliver(.snapshot([RosterItem(jid: bob)]), accountID: first)
        await fixture.deliver(.snapshot([RosterItem(jid: carol)]), accountID: second)
        let entered = AsyncSemaphore(), release = AsyncSemaphore()
        await store.installRosterApplyGate(entered: entered, release: release)
        let delayed = Task { await fixture.deliver(.snapshot([]), accountID: first) }
        try #require(try await boundedOutcome { await entered.wait() } != nil)
        await fixture.deliver(.snapshot([RosterItem(jid: carol, name: "Updated")]), accountID: second)
        #expect(fixture.service.contact(jidString: carol.description, accountID: second)?.name == "Updated")
        await release.signal()
        await delayed.value
        let readEntered = AsyncSemaphore(), readRelease = AsyncSemaphore()
        await store.installContactCaptureGate(entered: readEntered, release: readRelease)
        let reload = Task { try await fixture.service.loadContacts(for: second) }
        try #require(try await boundedOutcome { await readEntered.wait() } != nil)
        await fixture.deliver(.snapshot([]), accountID: second)
        await readRelease.signal()
        try await reload.value
        #expect(fixture.service.groups.isEmpty)
        fixture.service.purgeAccount(first)
        fixture.service.purgeAccount(second)
        for task in fixture.service.takePendingTasks() {
            await task.value
        }
    }
}
