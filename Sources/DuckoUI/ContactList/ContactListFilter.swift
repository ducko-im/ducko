import DuckoCore
import Foundation

/// Pure search → hide-offline → sort pipeline for the contact list, extracted
/// from `ContactListView` so the ordering and filtering rules are unit-testable.
/// Presence, unread messages and recency are injected as closures so the type stays in DuckoUI
/// without naming `BareJID`, which DuckoCore does not re-export.
enum ContactListFilter {
    /// Per-contact data the pipeline can't derive from a `Contact` alone:
    /// presence (for hide-offline and by-status), unread messages (which
    /// hide-offline keeps) and conversation recency.
    struct PresenceContext {
        let isOnline: (Contact) -> Bool
        let hasUnread: (Contact) -> Bool
        let statusPriority: (Contact) -> Int
        let lastMessageDate: (Contact) -> Date?
    }

    static func sortedAndFiltered(
        groups: [ContactGroup],
        searchText: String,
        hideOffline: Bool,
        sortMode: ContactListSortMode,
        context: PresenceContext
    ) -> [ContactGroup] {
        let searched: [ContactGroup] = searchText.isEmpty ? groups : groups.compactMap { group in
            let filtered = group.contacts.filter { contact in
                contact.displayName.localizedStandardContains(searchText)
                    || contact.jid.description.localizedStandardContains(searchText)
            }
            guard !filtered.isEmpty else { return nil }
            return ContactGroup(id: group.id, name: group.name, contacts: filtered)
        }

        // An offline contact with unread messages stays until the messages are read, so the list still shows who wrote.
        let filtered: [ContactGroup] = hideOffline ? searched.compactMap { group in
            let shown = group.contacts.filter { context.isOnline($0) || context.hasUnread($0) }
            guard !shown.isEmpty else { return nil }
            return ContactGroup(id: group.id, name: group.name, contacts: shown)
        } : searched

        return filtered.map { group in
            ContactGroup(
                id: group.id,
                name: group.name,
                contacts: sort(group.contacts, by: sortMode, context: context)
            )
        }
    }

    private static func sort(
        _ contacts: [Contact],
        by mode: ContactListSortMode,
        context: PresenceContext
    ) -> [Contact] {
        switch mode {
        case .alphabetical:
            return contacts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        case .byStatus:
            return contacts.sorted { a, b in
                let aPriority = context.statusPriority(a)
                let bPriority = context.statusPriority(b)
                if aPriority != bPriority {
                    return aPriority < bPriority
                }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }

        case .recentConversation:
            return contacts.sorted { a, b in
                let aDate = context.lastMessageDate(a)
                let bDate = context.lastMessageDate(b)
                if let aDate, let bDate {
                    return aDate > bDate
                }
                if aDate != nil { return true }
                if bDate != nil { return false }
                return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            }
        }
    }
}
