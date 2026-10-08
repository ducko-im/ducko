import DuckoCore
import Logging
import SwiftUI

private let log = Logger(label: "im.ducko.ui.transcripts")

@MainActor @Observable
public final class TranscriptViewerState {
    var allConversations: [Conversation] = [] {
        didSet {
            // A search over all conversations that had none to read starts over with the list that arrives. One that
            // has read some goes on: a refresh of the list never takes the results or the open day away.
            if searchesAllConversations, oldValue.isEmpty {
                invalidateSearch()
            }
        }
    }

    var accounts: [Account] = []
    private(set) var selection: TranscriptSelection?
    var messages: [ChatMessage] = []
    var notes: [TimelineNote] = []
    var positions: [UUID: MessagePosition] = [:]

    var timelineItems: [TimelineItem] {
        TimelineItem.merged(messages: messages, notes: notes)
    }

    /// The days of what is selected on the left, newest first.
    private(set) var days: [TranscriptDay] = []
    private(set) var selectedDay: TranscriptDay?

    /// Narrows the rows the left list shows. It does not narrow what a selected account or imported history covers.
    var sidebarFilter = "" {
        didSet {
            if isSelectionListed(filteredBy: oldValue) != isSelectionListed(filteredBy: sidebarFilter) {
                sidebarListGeneration += 1
            }
        }
    }

    /// Counted up when the left list has to be built anew. Left as it is, the list keeps a selected row painted where
    /// it was after the filter has hidden it, and shows it unselected when it comes back together with its section. A
    /// click that selects another row needs no new list, which stays scrolled to where the click was.
    private(set) var sidebarListGeneration = 0

    // MARK: - Search and find state

    /// The one keyword of the toolbar search field and the find bar.
    private(set) var keyword = ""
    /// Whether the keyword is searched for in every conversation, in place of what is selected on the left.
    private(set) var searchesAllConversations = false
    /// Whether the find bar was asked for, apart from a search over all conversations showing it.
    private(set) var isFinding = false
    /// The days with matches found so far, in the order they are listed.
    private(set) var dayMatches: [TranscriptDayMatches] = []
    /// Whether a search is still to run or still reading.
    private(set) var isScanning = false
    private(set) var currentMatchID: UUID?
    /// Counts the requests to put the cursor in the toolbar search field.
    private(set) var searchFieldFocusRequests = 0

    let remoteImageConsent = RemoteImageConsent()
    /// One scroller for the window, across days: each day shows from its first message.
    let scroller = TranscriptScroller()

    var isLoading: Bool {
        isLoadingAccounts || isLoadingDetail
    }

    private var isLoadingAccounts = false
    private var isLoadingDetail = false
    private var bootstrapRevision = 0
    private var listRevision = 0
    private var selectionRevision = 0
    private var searchRevision = 0
    /// Counts the reader's own choices of a row or a day, which a scope request that was waiting gives way to.
    private var choiceRevision = 0
    /// Contact photos by account and address.
    private var avatars: [UUID: [String: Data]] = [:]
    /// The search waiting out `searchDelay` or reading.
    @ObservationIgnored private(set) var pendingSearch: Task<Void, Never>?

    private let environment: AppEnvironment
    /// How long a keyword must stand before it is searched for, so that typing does not start a search per letter.
    private let searchDelay: Duration

    init(environment: AppEnvironment, searchDelay: Duration = .milliseconds(250)) {
        self.environment = environment
        self.searchDelay = searchDelay
    }

    // MARK: - Computed

    /// Accounts in their own order, then imported histories by address. A section with no row to show is left out.
    var sidebarSections: [TranscriptSidebarSection] {
        sections(filteredBy: sidebarFilter)
    }

    private func sections(filteredBy filter: String) -> [TranscriptSidebarSection] {
        let shown = filter.isEmpty ? allConversations : allConversations.filter { conversation in
            conversation.displayTitle.localizedStandardContains(filter)
                || conversation.jid.description.localizedStandardContains(filter)
        }
        var sections = accounts.map { account in
            TranscriptSidebarSection(
                selection: .account(account.id),
                title: account.displayName ?? account.jid.description,
                collapseKey: account.id.uuidString,
                conversations: shown.filter { $0.accountID == account.id }
            )
        }
        let imported = Dictionary(grouping: shown.filter { $0.accountID == nil }, by: Self.importSource)
        sections += imported.sorted { $0.key < $1.key }.map { source, conversations in
            TranscriptSidebarSection(selection: .importSource(source), title: source, collapseKey: source, conversations: conversations)
        }
        return sections.filter { !$0.conversations.isEmpty }
    }

    var shownConversation: Conversation? {
        selectedDay.flatMap { conversation(withID: $0.conversationID) }
    }

    var isFindBarVisible: Bool {
        isFinding || searchesAllConversations
    }

    /// The days the day list shows: a search's results while all conversations are searched, else the selection's.
    var listedDays: [TranscriptDay] {
        searchesAllConversations ? dayMatches.map(\.day) : days
    }

    var matchCounts: [TranscriptDay: Int] {
        Dictionary(dayMatches.map { ($0.day, $0.messageIDs.count) }, uniquingKeysWith: { first, _ in first })
    }

    var matchTotal: Int {
        dayMatches.reduce(0) { $0 + $1.messageIDs.count }
    }

    /// The current match's place among all matches found so far, counted from one, or nil while none is current.
    var currentMatchNumber: Int? {
        guard let currentMatchID else { return nil }
        return dayMatches.lazy.flatMap(\.messageIDs).firstIndex(of: currentMatchID).map { $0 + 1 }
    }

    /// The ids of the open day's matching messages.
    var shownMatchIDs: Set<UUID> {
        Set(dayMatches.first { $0.day == selectedDay }?.messageIDs ?? [])
    }

    /// Whether a finished search found nothing. Never true while a search is still to run or reading.
    var hasNoResults: Bool {
        !trimmedKeyword.isEmpty && !isScanning && dayMatches.isEmpty
    }

    var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespaces)
    }

    /// What the toolbar search field shows.
    var searchFieldText: String {
        searchesAllConversations ? keyword : ""
    }

    /// What the left list shows selected. During a search over all conversations no row is, which also makes a click
    /// on the row selected before reach `select(_:)`.
    var sidebarSelection: TranscriptSelection? {
        searchesAllConversations ? nil : selection
    }

    /// Whether the left list has the selected row under `filter`. With nothing selected there is no row to miss.
    private func isSelectionListed(filteredBy filter: String) -> Bool {
        guard let selection else { return true }
        return sections(filteredBy: filter).contains { section in
            section.selection == selection || section.conversations.contains { .conversation($0.id) == selection }
        }
    }

    func conversation(withID id: UUID) -> Conversation? {
        allConversations.first { $0.id == id }
    }

    /// The stored photo of the contact a conversation is with, or nil for one without an account or a stored contact.
    func avatarData(for conversation: Conversation) -> Data? {
        conversation.accountID.flatMap { avatars[$0]?[conversation.jid.description] }
    }

    private static func importSource(of conversation: Conversation) -> String {
        conversation.importSourceJID ?? "Unknown"
    }

    /// Every conversation a selection covers, whatever the left list's filter shows.
    private func conversationIDs(of selection: TranscriptSelection) -> [UUID] {
        switch selection {
        case let .account(accountID):
            allConversations.filter { $0.accountID == accountID }.map(\.id)
        case let .importSource(source):
            allConversations.filter { $0.accountID == nil && Self.importSource(of: $0) == source }.map(\.id)
        case let .conversation(id):
            [id]
        }
    }

    // MARK: - Loading

    /// Loads the lists and shows what `request` asks for. Without a request it shows the first section of the left list.
    func start(with request: ScopeRequest?) async {
        await load()
        if let request {
            await applyScope(request)
        }
        await selectDefaultSection()
    }

    func load() async {
        bootstrapRevision += 1
        let bootstrap = bootstrapRevision
        let list = listRevision
        isLoadingAccounts = true
        defer {
            if bootstrap == bootstrapRevision { isLoadingAccounts = false }
        }

        do {
            try await environment.accountService.loadAccounts()
            guard bootstrap == bootstrapRevision else { return }
            accounts = environment.accountService.accounts
            // Before the rows that show them, so that no row starts out with initials.
            let photos = await storedAvatars()
            guard bootstrap == bootstrapRevision else { return }
            avatars = photos
            guard list == listRevision else { return }
            let conversations = try await environment.chatService.fetchAllConversations()
            guard bootstrap == bootstrapRevision, list == listRevision else { return }
            allConversations = conversations
        } catch {
            guard bootstrap == bootstrapRevision else { return }
            log.error("Failed to load transcripts: \(error)")
        }
    }

    /// Read from the store, since the contact list only holds the contacts of enabled accounts.
    private func storedAvatars() async -> [UUID: [String: Data]] {
        var photos: [UUID: [String: Data]] = [:]
        for account in accounts {
            for contact in await environment.rosterService.storedContacts(for: account.id) {
                photos[account.id, default: [:]][contact.jid.description] = contact.avatarData
            }
        }
        return photos
    }

    /// A scope request that was taken up shows its own conversation or leaves the selection alone, so the default is
    /// never put in its way.
    private func selectDefaultSection() async {
        guard selection == nil, appliedScopeGeneration == 0 else { return }
        let first = sidebarSections.first?.selection
        guard !searchesAllConversations else {
            // A keyword typed while the lists were loading is being searched for. The default waits behind it.
            selection = first
            return
        }
        guard let first else { return }
        await loadSelection(first)?.value
    }

    // MARK: - Selection

    /// Selects a row of the left list and returns the load of its days. A row selected again is loaded again.
    @discardableResult
    func select(_ newSelection: TranscriptSelection?) -> Task<Void, Never>? {
        choiceRevision += 1
        if searchesAllConversations {
            // The click ends the search, and its keyword goes on as a find within the clicked row.
            searchesAllConversations = false
            isFinding = true
        }
        return loadSelection(newSelection)
    }

    /// Selects a day of the day list and returns the load of its messages.
    @discardableResult
    func selectDay(_ day: TranscriptDay?) -> Task<Void, Never>? {
        choiceRevision += 1
        return openDay(day)
    }

    private func loadSelection(_ newSelection: TranscriptSelection?) -> Task<Void, Never>? {
        let openDay = selectedDay
        selection = newSelection
        days = []
        clearDay()
        invalidateSearch()
        guard let newSelection else { return nil }
        let revision = selectionRevision
        isLoadingDetail = true
        return Task { await loadDays(of: newSelection, reopening: openDay, revision: revision) }
    }

    /// Lists the selection's days and opens one: the day that was open before when it is among them, else the newest.
    private func loadDays(of selection: TranscriptSelection, reopening openDay: TranscriptDay?, revision: Int) async {
        defer {
            if revision == selectionRevision { isLoadingDetail = false }
        }
        do {
            let loaded = try await environment.chatService.transcriptDays(for: conversationIDs(of: selection))
            guard revision == selectionRevision else { return }
            days = loaded
            guard let day = openDay.flatMap({ loaded.contains($0) ? $0 : nil }) ?? loaded.first else { return }
            selectedDay = day
            try await loadDay(day, revision: revision)
        } catch {
            guard revision == selectionRevision else { return }
            log.error("Failed to load conversation transcript: \(error)")
        }
    }

    private func openDay(_ day: TranscriptDay?) -> Task<Void, Never>? {
        clearDay()
        selectedDay = day
        if let currentMatchID, !shownMatchIDs.contains(currentMatchID) {
            self.currentMatchID = nil
        }
        guard let day else { return nil }
        let revision = selectionRevision
        isLoadingDetail = true
        return Task {
            defer {
                if revision == selectionRevision { isLoadingDetail = false }
            }
            do {
                try await loadDay(day, revision: revision)
            } catch {
                guard revision == selectionRevision else { return }
                log.error("Failed to load messages for date: \(error)")
            }
        }
    }

    /// Empties the message pane. A load of a day that is still waiting publishes nothing after this.
    private func clearDay() {
        selectionRevision += 1
        selectedDay = nil
        messages = []
        notes = []
        positions = [:]
        scroller.reset(to: .oldest)
        isLoadingDetail = false
    }

    private func loadDay(_ day: TranscriptDay, revision: Int) async throws {
        let dayMessages = try await environment.chatService.fetchMessageHistory(for: day.conversationID, on: day.date)
        // A transcript day is a UTC day, the span one transcript file covers.
        let dayNotes = await environment.chatService.fetchNotes(
            for: day.conversationID, since: day.date, before: day.date.addingTimeInterval(24 * 60 * 60)
        )
        guard revision == selectionRevision else { return }
        messages = dayMessages
        notes = dayNotes
        positions = computeMessagePositions(timelineItems)
        scroller.reset(to: .oldest)
        if let currentMatchID, dayMessages.contains(where: { $0.id == currentMatchID }) {
            scroller.revealWhenShown(currentMatchID)
        }
    }

    // MARK: - Scoping

    private var appliedScopeGeneration = 0

    /// A refresh may update the sidebar, but only a resolved target can supersede detail work.
    /// A choice the reader made while the refresh awaits takes precedence over that scope.
    func applyScope(_ request: ScopeRequest) async {
        guard request.generation > appliedScopeGeneration else { return }
        appliedScopeGeneration = request.generation
        let choice = choiceRevision
        let refreshed = try? await environment.chatService.fetchAllConversations()
        guard request.generation == appliedScopeGeneration else { return }
        if let refreshed {
            listRevision += 1
            allConversations = refreshed
        }
        guard choice == choiceRevision,
              let match = allConversations.first(where: { request.ref.matches($0) }) else { return }
        resetFind()
        await loadSelection(.conversation(match.id))?.value
    }

    // MARK: - Search and find

    /// The toolbar field's setter: a keyword there is searched for in all conversations.
    func setSearchText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Spaces alone start nothing.
        guard searchesAllConversations || !trimmed.isEmpty else { return }
        let previous = trimmedKeyword
        let wasSearching = searchesAllConversations
        keyword = trimmed.isEmpty ? "" : text
        searchesAllConversations = !trimmed.isEmpty
        if !searchesAllConversations {
            returnToSelection()
        } else if !wasSearching || trimmed != previous {
            invalidateSearch()
        }
    }

    /// The find bar's setter. Emptying it during a search over all conversations ends that search and keeps the bar open.
    func setFindText(_ text: String) {
        let previous = trimmedKeyword
        keyword = text
        guard trimmedKeyword != previous else { return }
        if trimmedKeyword.isEmpty, searchesAllConversations {
            searchesAllConversations = false
            isFinding = true
            returnToSelection()
        } else {
            invalidateSearch()
        }
    }

    public func toggleFind() {
        if isFindBarVisible {
            endFind()
        } else {
            isFinding = true
        }
    }

    /// Closes the find bar. It ends a search over all conversations as well.
    func endFind() {
        let wasSearchingAll = searchesAllConversations
        resetFind()
        if wasSearchingAll {
            returnToSelection()
        } else {
            invalidateSearch()
        }
    }

    public func focusSearchField() {
        searchFieldFocusRequests += 1
    }

    /// Returns the load of the match's day when the match is on another day than the open one.
    @discardableResult
    func findNext() -> Task<Void, Never>? {
        stepFind(forward: true)
    }

    @discardableResult
    func findPrevious() -> Task<Void, Never>? {
        stepFind(forward: false)
    }

    private func resetFind() {
        keyword = ""
        searchesAllConversations = false
        isFinding = false
    }

    /// After a search over all conversations, the day list shows the selection's days again. The open day stays when
    /// it is one of them. Otherwise the selection is loaded again, which also covers a load the search had dropped.
    private func returnToSelection() {
        if let selectedDay, days.contains(selectedDay) {
            invalidateSearch()
        } else {
            _ = loadSelection(selection)
        }
    }

    /// The one place results are dropped and the one place a search is scheduled.
    private func invalidateSearch() {
        searchRevision += 1
        dayMatches = []
        currentMatchID = nil
        pendingSearch?.cancel()
        pendingSearch = nil
        if searchesAllConversations {
            // The day shown always belongs to the current keyword.
            clearDay()
        }
        guard !trimmedKeyword.isEmpty, isFindBarVisible else {
            isScanning = false
            return
        }
        isScanning = true
        pendingSearch = Task {
            try? await Task.sleep(for: searchDelay)
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    /// Reads the days of all conversations, or of the selection, one at a time from the newest on, and lists each day
    /// with matches as it is found. A run that a newer search superseded reads no further day and publishes nothing.
    func runSearch() async {
        let revision = searchRevision
        let query = trimmedKeyword
        let searchesAll = searchesAllConversations
        let scope = searchesAll ? allConversations.map(\.id) : selection.map(conversationIDs(of:)) ?? []
        do {
            let scanned = try await environment.chatService.transcriptDays(for: scope)
            for day in scanned {
                guard revision == searchRevision else { return }
                let matches = try await environment.chatService.matchingMessages(query, on: day)
                guard revision == searchRevision else { return }
                guard let first = matches.first else { continue }
                dayMatches.append(TranscriptDayMatches(day: day, messageIDs: matches.map(\.id)))
                if searchesAll, selectedDay == nil {
                    currentMatchID = first.id
                    await openDay(day)?.value
                }
            }
        } catch {
            guard revision == searchRevision else { return }
            log.error("Failed to search transcripts: \(error)")
        }
        guard revision == searchRevision else { return }
        isScanning = false
    }

    /// Moves to the match after or before the current one in the order the matches are listed: by day, then by place
    /// within the day, wrapping at the ends. With no current match it starts from the open day.
    private func stepFind(forward: Bool) -> Task<Void, Never>? {
        let matches = dayMatches.flatMap { entry in entry.messageIDs.map { (day: entry.day, id: $0) } }
        guard !matches.isEmpty else { return nil }
        let target: (day: TranscriptDay, id: UUID)
        if let current = matches.firstIndex(where: { $0.id == currentMatchID }) {
            target = matches[(current + (forward ? 1 : -1) + matches.count) % matches.count]
        } else {
            let places = Dictionary(listedDays.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let open = selectedDay.flatMap { places[$0] }
            if forward {
                let entry = open.flatMap { open in dayMatches.first { places[$0.day, default: -1] >= open } } ?? dayMatches[0]
                target = (entry.day, entry.messageIDs[0])
            } else {
                let entry = open.flatMap { open in dayMatches.last { places[$0.day, default: .max] <= open } }
                    ?? dayMatches[dayMatches.count - 1]
                target = (entry.day, entry.messageIDs[entry.messageIDs.count - 1])
            }
        }
        currentMatchID = target.id
        guard target.day != selectedDay else {
            scroller.revealWhenShown(target.id)
            return nil
        }
        // The day's messages reveal the match once they are in.
        return openDay(target.day)
    }
}
