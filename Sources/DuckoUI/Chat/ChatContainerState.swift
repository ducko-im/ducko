import DuckoCore
import SwiftUI

/// App-owned state for the single tabbed chat window. Retains each open tab's
/// `ChatWindowState` in `states` so switching tabs never destroys per-conversation UI
/// state (draft, search, reply/edit, sidebar). Tabs are keyed by `ConversationKey`
/// (account + full open-string JID), so the same peer JID under two accounts opens two
/// distinct tabs, and a MUC PM (`room@conf/nick`) stays distinct from the room (`room@conf`).
@MainActor @Observable
public final class ChatContainerState {
    public private(set) var orderedTabs: [ConversationKey] = [] {
        didSet { saveTabs() }
    }

    private var states: [ConversationKey: ChatWindowState] = [:]
    public var selectedKey: ConversationKey? {
        didSet {
            saveTabs()
            // The chat window's one file importer rebinds to the newly selected tab, so the outgoing tab's request
            // would otherwise reopen the picker when that tab comes back.
            guard let oldValue, oldValue != selectedKey else { return }
            states[oldValue]?.isShowingFileImporter = false
        }
    }

    /// Whether the chat window is open. Saved with the tabs, so a relaunch knows whether to bring it back.
    public var isWindowOpen = false {
        didSet { saveTabs() }
    }

    /// Whether the chat window is the focused window of the active app.
    public var isWindowFocused = false {
        didSet { inViewChanged(from: oldValue && !isOpeningQuietly) }
    }

    /// Set while the window, opened on its own for a contact's message or file offer, is still being put behind the
    /// window the user is in. It can be the focused window for a moment then, without the user having gone to it.
    public var isOpeningQuietly = false {
        didSet { inViewChanged(from: isWindowFocused && !oldValue) }
    }

    /// Whether the user is looking at the chat window. The selected tab is the active conversation only while they
    /// are: messages arriving in a chat window that is closed, behind another window, in a backgrounded app, or only
    /// just opening on its own are unread, not seen.
    private var isInView: Bool {
        isWindowFocused && !isOpeningQuietly
    }

    private func inViewChanged(from wasInView: Bool) {
        guard isInView != wasInView else { return }
        if isInView, let selectedState {
            scheduleActivation(of: selectedState)
        } else {
            scheduleDeactivation()
        }
    }

    /// Drives the container-owned New Chat sheet so the tab-bar "+" and the menu-bar
    /// New Chat command work when the chat window is frontmost — the Contacts window
    /// (owner of the original new-chat sheet) isn't the focused scene then.
    public var isShowingNewChat = false

    private let environment: AppEnvironment
    private let defaults: UserDefaults

    public init(environment: AppEnvironment, defaults: UserDefaults) {
        self.environment = environment
        self.defaults = defaults
    }

    public var selectedState: ChatWindowState? {
        selectedKey.flatMap { states[$0] }
    }

    public var hasTabs: Bool {
        !orderedTabs.isEmpty
    }

    /// False while the New Chat sheet or the file importer is up: tab shortcuts still reach the window behind them,
    /// and a switch would rebind the open importer to another tab.
    public var canCycleTabs: Bool {
        orderedTabs.count > 1 && !isShowingNewChat && selectedState?.isShowingFileImporter != true
    }

    public func state(for key: ConversationKey) -> ChatWindowState? {
        states[key]
    }

    // MARK: - Tab Lifecycle

    public func open(_ jidString: String, accountID: UUID?) {
        let key = ConversationKey(accountID: accountID, jid: jidString)
        if states[key] == nil {
            addTab(key, selecting: true)
        } else {
            select(key)
        }
    }

    /// Adds a tab without switching to it. It becomes the selected tab only when there is no other.
    public func openInBackground(_ jidString: String, accountID: UUID?) {
        let key = ConversationKey(accountID: accountID, jid: jidString)
        guard states[key] == nil else { return }
        addTab(key, selecting: selectedKey == nil)
    }

    private func addTab(_ key: ConversationKey, selecting: Bool) {
        let state = ChatWindowState(jidString: key.jid, accountID: key.accountID, environment: environment)
        states[key] = state
        orderedTabs.append(key)
        if selecting {
            selectedKey = key
            // While the window is in view, `load()` ends by calling `chatService.selectConversation`,
            // so the freshly opened tab becomes the active conversation without a separate
            // activation. Otherwise it is activated when the window comes into view.
            // Bump the generation so any in-flight select/close activation finds itself
            // stale and bails instead of re-pointing the active conversation behind this
            // newly opened, now-selected tab.
            activationGeneration += 1
        }
        Task { await state.load { [weak self, weak state] in self?.canActivate(state) ?? false } }
    }

    public func select(_ key: ConversationKey) {
        guard let state = states[key], selectedKey != key else { return }
        selectedKey = key
        scheduleActivation(of: state)
    }

    public func selectNextTab() {
        selectTab(offsetBy: 1)
    }

    public func selectPreviousTab() {
        selectTab(offsetBy: -1)
    }

    private func selectTab(offsetBy offset: Int) {
        guard orderedTabs.count > 1, let selectedKey, let index = orderedTabs.firstIndex(of: selectedKey) else { return }
        select(orderedTabs[(index + offset + orderedTabs.count) % orderedTabs.count])
    }

    public func close(_ key: ConversationKey) {
        guard let index = orderedTabs.firstIndex(of: key) else { return }
        orderedTabs.remove(at: index)
        states.removeValue(forKey: key)

        guard selectedKey == key else { return }
        // Pick the tab that shifted into this slot, else the new last tab.
        let neighbor = orderedTabs.indices.contains(index) ? orderedTabs[index] : orderedTabs.last
        selectedKey = neighbor
        if let neighbor, let state = states[neighbor] {
            scheduleActivation(of: state)
        } else {
            scheduleDeactivation()
        }
    }

    public func closeAll() {
        orderedTabs.removeAll()
        states.removeAll()
        selectedKey = nil
        scheduleDeactivation()
    }

    public func newChat() {
        isShowingNewChat = true
    }

    /// Closes any open tab whose backing conversation no longer exists in the
    /// service — e.g. a destroyed MUC room that `ChatService.handleRoomDestroyed`
    /// removed from `openConversations` — so a deleted conversation can't linger
    /// as a usable tab. Tabs still mid-`load()` (nil conversation) are left alone;
    /// they aren't in `openConversations` yet but aren't stale either. Driven by
    /// `ChatContainerView` observing `chatService.openConversations`.
    public func pruneClosedConversations() {
        let liveIDs = Set(environment.chatService.openConversations.map(\.id))
        let stale = orderedTabs.filter { key in
            guard let id = states[key]?.conversation?.id else { return false }
            return !liveIDs.contains(id)
        }
        for key in stale {
            close(key)
        }
    }

    // MARK: - Restoring After a Relaunch

    private struct SavedTabs: Codable {
        let orderedTabs: [ConversationKey]
        let selectedKey: ConversationKey?
        let isWindowOpen: Bool
    }

    private enum Keys {
        static let savedTabs = "chatSavedTabs"
    }

    private var hasRestoredTabs = false
    private var isQuitting = false

    /// Reopens the tabs that were open when the app last ran, leaving out those of an account that is gone or
    /// disabled. Returns whether the chat window was open then and has a tab to show. Call after the accounts have
    /// loaded: before that, every tab counts as belonging to no account and is left out.
    public func restoreTabs() -> Bool {
        guard !hasRestoredTabs else { return false }
        // What is open now replaces the last session's record, whether or not there was one to restore.
        defer {
            hasRestoredTabs = true
            saveTabs()
        }
        guard let data = defaults.data(forKey: Keys.savedTabs),
              let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) else { return false }

        let enabledAccountIDs = Set(environment.accountService.enabledAccounts.map(\.id))
        let tabs = saved.orderedTabs.filter { key in
            guard let accountID = key.accountID else { return false }
            return enabledAccountIDs.contains(accountID)
        }
        let savedSelection = saved.selectedKey.flatMap { tabs.contains($0) ? $0 : nil }
        // A chat opened before this ran is the one the user asked for, so it stays selected.
        let selected = selectedKey ?? savedSelection ?? tabs.first
        for key in tabs where states[key] == nil {
            addTab(key, selecting: key == selected)
        }
        return saved.isWindowOpen && hasTabs
    }

    /// Call when the app starts to quit. Its windows close on the way out, which is not the user closing the chat
    /// window, so what is saved stays as it was at that moment.
    public func stopSavingTabs() {
        isQuitting = true
    }

    private func saveTabs() {
        // Until the last session's tabs are back, saving would replace them with a launch's empty window.
        guard hasRestoredTabs, !isQuitting else { return }
        let saved = SavedTabs(orderedTabs: orderedTabs, selectedKey: selectedKey, isWindowOpen: isWindowOpen)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Keys.savedTabs)
    }

    // MARK: - Activation

    /// Bumped on every activation request. A stale activation still mid-`await` when the
    /// user selects a newer tab finds its generation no longer current and discards itself,
    /// rather than re-pointing the active conversation (and marking it read) behind the
    /// now-visible tab.
    private var activationGeneration = 0

    /// True only while `state` is the selected tab's own instance in a chat window that is in view, so a load finishing
    /// in a background, closed, or reopened tab, or in a window nobody is looking at, can't activate it.
    private func canActivate(_ state: ChatWindowState?) -> Bool {
        guard isInView, let state, let selectedKey else { return false }
        return states[selectedKey] === state
    }

    private func scheduleActivation(of state: ChatWindowState) {
        activationGeneration += 1
        let generation = activationGeneration
        Task { await activate(state, generation: generation) }
    }

    /// Clears `ChatService.activeConversationID` when the last tab closes or the window goes
    /// out of view. Otherwise it keeps pointing at a conversation nobody is looking at, which
    /// `ChatService` treats as active — auto-marking its incoming messages read and suppressing
    /// their unread count.
    private func scheduleDeactivation() {
        activationGeneration += 1
        let generation = activationGeneration
        Task {
            guard generation == activationGeneration else { return }
            await environment.chatService.selectConversation(nil)
        }
    }

    /// Re-points `ChatService.activeConversationID` at the now-visible tab and refreshes
    /// its messages. `selectConversation` reloads `ChatService.messages` and marks read but
    /// does not touch the tab's retained `ChatWindowState.messages`, so we refresh it
    /// directly rather than relying on the order/equality-fragile `.onChange` observers —
    /// otherwise a freshly-activated hidden tab could be marked read while showing stale
    /// messages received while it was hidden.
    private func activate(_ state: ChatWindowState, generation: Int) async {
        guard generation == activationGeneration, isInView else { return }
        guard let conversationID = state.conversation?.id else { return }
        let accountID = state.conversation?.accountID ?? environment.accountService.accounts.first?.id
        await environment.chatService.selectConversation(conversationID, accountID: accountID)
        guard generation == activationGeneration else { return }
        await state.refreshMessages()
    }
}
