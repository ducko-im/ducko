import DuckoCore
import SwiftUI

/// SwiftUI host for the AppKit contact list. Computes the filtered, sorted
/// visible rows here — reading the roster, presence, open conversations, and
/// expand state inside `body` so a change in any of them re-renders and feeds
/// fresh rows to `ContactListTableView`, which owns the diff, measurement, and
/// the co-animated window resize.
struct ContactListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Bindable var windowState: ContactListWindowState
    let chromeHeight: CGFloat
    @AppStorage(ContactListSizingDefaults.autoSizeVerticalKey, store: PreferencesDefaults.store)
    private var autoSizeVertical = true
    @AppStorage(ContactListSizingDefaults.autoSizeHorizontalKey, store: PreferencesDefaults.store)
    private var autoSizeHorizontal = true
    @AppStorage(ContactListSizingDefaults.maxWidthKey, store: PreferencesDefaults.store)
    private var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth
    @AppStorage(ContactListSizingDefaults.compactKey, store: PreferencesDefaults.store)
    private var isCompact = false

    private var preferences: ContactListPreferences {
        windowState.preferences
    }

    private var roomConversations: [Conversation] {
        environment.chatService.openConversations.filter { $0.type == .groupchat }
    }

    /// The room a just-completed create flow marked, so its settings sheet can
    /// auto-open.
    private var newlyCreatedRoom: Conversation? {
        roomConversations.first { room in
            guard let accountID = room.accountID else { return false }
            return environment.chatService.isRoomNewlyCreated(jidString: room.jid.description, accountID: accountID)
        }
    }

    /// True when at least one enabled account has reached `.connected`.
    /// UI integration tests poll the matching AX sentinel (re-exposed on the
    /// `contact-list` container) to gate on the live handshake completing —
    /// `contact-row-*` can render from the cached roster before the new client
    /// finishes binding, so it is not a safe connectivity gate by itself.
    private var hasConnectedAccount: Bool {
        environment.accountService.hasAnyConnectedAccount
    }

    var body: some View {
        // Resolve the filtered roster and open rooms once: the rows and the
        // group counts both read them. Presence is read per contact
        // (account-scoped) rather than from a merged map, so a same-JID peer on
        // two accounts counts under the right account.
        let groups = sortedAndFilteredGroups
        let rooms = roomConversations
        let unfilteredGroups = environment.rosterService.groups
        let rows = ContactListRowBuilder.rows(
            groups: groups,
            rooms: rooms,
            isGroupExpanded: { preferences.isGroupExpanded($0) },
            counts: { group in
                ContactListSizing.onlineCounts(
                    groupID: group.id,
                    unfilteredRoster: unfilteredGroups,
                    displayedContacts: group.contacts
                ) { environment.presenceService.presence(for: $0.jid, accountID: $0.accountID) != nil }
            }
        )

        ContactListTableView(
            rows: rows,
            preferences: preferences,
            chromeHeight: chromeHeight,
            autoSizeVertical: autoSizeVertical,
            autoSizeHorizontal: autoSizeHorizontal,
            maxWidthPreference: maxWidthPreference,
            isCompact: isCompact,
            hasConnectedAccount: hasConnectedAccount,
            presentSheet: { windowState.activeRowSheet = $0 },
            requestRemoval: { windowState.requestRemoval(of: $0) },
            onSelectionChange: { windowState.selectedRow = $0 }
        )
        // The table-owned AppKit context menu routes sheet presentation back
        // here, where SwiftUI owns it.
        .sheet(item: $windowState.activeRowSheet) { sheet in
            switch sheet {
            case let .rename(contact):
                RenameContactSheet(contact: contact)
            case let .invite(conversation):
                InviteUserSheet(conversation: conversation)
            case let .roomSettings(conversation):
                if let accountID = conversation.accountID {
                    RoomSettingsView(roomJIDString: conversation.jid.description, accountID: accountID)
                }
            }
        }
        // Auto-open a freshly-created room's settings once, then clear the flag
        // so it doesn't re-trigger. `initial: true` covers a room already marked
        // newly-created before this view mounts (e.g. created while the window
        // was closed).
        .onChange(of: newlyCreatedRoom?.id, initial: true) { _, newID in
            guard let newID, let room = roomConversations.first(where: { $0.id == newID }),
                  let accountID = room.accountID else { return }
            windowState.activeRowSheet = .roomSettings(room)
            environment.chatService.clearNewlyCreatedRoom(room.jid.description, accountID: accountID)
        }
    }

    private var sortedAndFilteredGroups: [ContactGroup] {
        // Key the last-message map by account+JID: two accounts' conversations with the same peer
        // JID would otherwise collide and the "recent conversation" sort would read the wrong date.
        var lastMessageDates: [ConversationKey: Date] = [:]
        for conversation in environment.chatService.openConversations {
            if let date = conversation.lastMessageDate {
                lastMessageDates[ConversationKey(accountID: conversation.accountID, jid: conversation.jid.description)] = date
            }
        }
        let presenceService = environment.presenceService

        return ContactListFilter.sortedAndFiltered(
            groups: environment.rosterService.groups,
            searchText: windowState.searchText,
            hideOffline: preferences.hideOffline,
            sortMode: preferences.sortMode,
            context: ContactListFilter.PresenceContext(
                isOnline: { presenceService.presence(for: $0.jid, accountID: $0.accountID) != nil },
                statusPriority: { statusPriority(of: presenceService.presence(for: $0.jid, accountID: $0.accountID)) },
                lastMessageDate: { lastMessageDates[ConversationKey(accountID: $0.accountID, jid: $0.jid.description)] }
            )
        )
    }

    private func statusPriority(of status: PresenceService.PresenceStatus?) -> Int {
        guard let status else { return 4 }
        return switch status {
        case .available: 0
        case .away: 1
        case .dnd: 2
        case .xa: 3
        case .offline: 4
        }
    }
}
