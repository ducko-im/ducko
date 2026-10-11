import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoUI

struct ContactListFilterTests {
    private static func contact(_ local: String, name: String? = nil) -> Contact {
        Contact(
            id: UUID(),
            accountID: UUID(),
            jid: BareJID(localPart: local, domainPart: "example.com")!,
            name: name,
            subscription: .both,
            groups: [],
            isBlocked: false,
            createdAt: Date()
        )
    }

    private static func group(_ contacts: [Contact], id: String = "g", name: String = "Friends") -> ContactGroup {
        ContactGroup(id: id, name: name, contacts: contacts)
    }

    private static func run(
        _ groups: [ContactGroup],
        searchText: String = "",
        hideOffline: Bool = false,
        sortMode: ContactListSortMode = .alphabetical,
        online: Set<String> = [],
        unread: Set<String> = [],
        priority: [String: Int] = [:],
        dates: [String: Date] = [:]
    ) -> [ContactGroup] {
        ContactListFilter.sortedAndFiltered(
            groups: groups,
            searchText: searchText,
            hideOffline: hideOffline,
            sortMode: sortMode,
            context: ContactListFilter.PresenceContext(
                isOnline: { online.contains($0.jid.localPart ?? "") },
                hasUnread: { unread.contains($0.jid.localPart ?? "") },
                statusPriority: { priority[$0.jid.localPart ?? ""] ?? 4 },
                lastMessageDate: { dates[$0.jid.localPart ?? ""] }
            )
        )
    }

    // MARK: - Search

    @Test func `search filters contacts by display name`() {
        let result = Self.run(
            [Self.group([Self.contact("alice", name: "Alice"), Self.contact("bob", name: "Bob")])],
            searchText: "ali"
        )
        #expect(result.count == 1)
        #expect(result[0].contacts.map(\.jid.localPart) == ["alice"])
    }

    @Test func `search also matches the JID, not just the display name`() {
        let result = Self.run([Self.group([Self.contact("alice", name: "Wonderland")])], searchText: "alice")
        #expect(result[0].contacts.count == 1)
    }

    @Test func `search matching nothing drops the group entirely`() {
        let result = Self.run([Self.group([Self.contact("alice", name: "Alice")])], searchText: "zzz")
        #expect(result.isEmpty)
    }

    // MARK: - Hide offline

    @Test func `hideOffline keeps only online contacts and drops fully-offline groups`() {
        let groups = [
            Self.group([Self.contact("alice"), Self.contact("bob")], id: "g1", name: "G1"),
            Self.group([Self.contact("carol")], id: "g2", name: "G2")
        ]
        let result = Self.run(groups, hideOffline: true, online: ["alice"])
        #expect(result.count == 1)
        #expect(result[0].id == "g1")
        #expect(result[0].contacts.map(\.jid.localPart) == ["alice"])
    }

    @Test func `hideOffline keeps an offline contact with unread messages`() {
        let groups = [
            Self.group([Self.contact("alice"), Self.contact("bob")], id: "g1", name: "G1"),
            Self.group([Self.contact("carol")], id: "g2", name: "G2")
        ]
        let result = Self.run(groups, hideOffline: true, unread: ["bob"])
        #expect(result.count == 1)
        #expect(result[0].id == "g1")
        #expect(result[0].contacts.map(\.jid.localPart) == ["bob"])
    }

    @Test func `hideOffline disabled retains offline contacts`() {
        let result = Self.run([Self.group([Self.contact("alice")])], hideOffline: false, online: [])
        #expect(result[0].contacts.count == 1)
    }

    @Test func `search and hideOffline compose: a matching but offline contact is dropped`() {
        // "alice" matches the search but is offline; only the matching online
        // contact survives both stages.
        let result = Self.run(
            [Self.group([Self.contact("alice", name: "Alice"), Self.contact("alicia", name: "Alicia")])],
            searchText: "ali",
            hideOffline: true,
            online: ["alicia"]
        )
        #expect(result.count == 1)
        #expect(result[0].contacts.map(\.jid.localPart) == ["alicia"])
    }

    // MARK: - Sort

    @Test func `alphabetical sort orders by display name`() {
        let result = Self.run(
            [Self.group([Self.contact("c", name: "Charlie"), Self.contact("a", name: "Alice"), Self.contact("b", name: "Bob")])],
            sortMode: .alphabetical
        )
        #expect(result[0].contacts.map(\.displayName) == ["Alice", "Bob", "Charlie"])
    }

    @Test func `byStatus sort orders by presence priority then name`() {
        let result = Self.run(
            [Self.group([
                Self.contact("z", name: "Zoe"), // priority 4 (offline)
                Self.contact("y", name: "Yan"), // priority 0 (available)
                Self.contact("m", name: "Mara"), // priority 1 (away)
                Self.contact("a", name: "Abe") // priority 1 (away)
            ])],
            sortMode: .byStatus,
            priority: ["y": 0, "m": 1, "a": 1, "z": 4]
        )
        // available first, then the away tier alphabetically, then offline last.
        #expect(result[0].contacts.map(\.displayName) == ["Yan", "Abe", "Mara", "Zoe"])
    }

    @Test func `byStatus sort falls back to alphabetical when all contacts share a priority`() {
        // No priorities supplied → every contact defaults to 4, so the
        // comparator falls fully through to the name tiebreak.
        let result = Self.run(
            [Self.group([Self.contact("c", name: "Charlie"), Self.contact("a", name: "Alice"), Self.contact("b", name: "Bob")])],
            sortMode: .byStatus
        )
        #expect(result[0].contacts.map(\.displayName) == ["Alice", "Bob", "Charlie"])
    }

    @Test func `recentConversation sort puts most recent first then undated alphabetically`() {
        let now = Date()
        let result = Self.run(
            [Self.group([
                Self.contact("a", name: "Alice"), // dated, older
                Self.contact("c", name: "Carol"), // undated
                Self.contact("b", name: "Bob"), // dated, newer
                Self.contact("d", name: "Dave") // undated
            ])],
            sortMode: .recentConversation,
            dates: ["a": now.addingTimeInterval(-3600), "b": now]
        )
        #expect(result[0].contacts.map(\.displayName) == ["Bob", "Alice", "Carol", "Dave"])
    }
}
