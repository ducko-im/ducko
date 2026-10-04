import DuckoCore
import Logging
import SwiftUI

private let log = Logger(label: "im.ducko.ui.transcripts")

@MainActor @Observable
final class TranscriptViewerState {
    var allConversations: [Conversation] = []
    var accounts: [Account] = []
    var selectedConversation: Conversation?
    var messages: [ChatMessage] = []
    var notes: [TimelineNote] = []
    var positions: [UUID: MessagePosition] = [:]

    var timelineItems: [TimelineItem] {
        TimelineItem.merged(messages: messages, notes: notes)
    }

    // Date-based detail navigation
    var messageDates: [Date] = []
    var messageDateCounts: [Date: Int] = [:]
    var selectedDate: Date?

    // Sidebar filters
    var searchText = ""
    var typeFilter: ConversationTypeFilter = .all

    var transcriptSearchText = "" {
        didSet {
            guard transcriptSearchText != oldValue else { return }
            invalidateSearch()
        }
    }

    var searchResults: Set<UUID> = []
    var searchMatchDates: Set<Date> = []

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

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Computed

    var filteredConversations: [Conversation] {
        var result = allConversations

        switch typeFilter {
        case .all: break
        case .chats: result = result.filter { $0.type == .chat }
        case .rooms: result = result.filter { $0.type == .groupchat }
        }

        if !searchText.isEmpty {
            result = result.filter { conversation in
                let name = conversation.displayTitle
                return name.localizedCaseInsensitiveContains(searchText)
                    || conversation.jid.description.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }

    private var partitionedConversations: (byAccount: [UUID: [Conversation]], importedBySource: [String: [Conversation]]) {
        let filtered = filteredConversations
        var grouped: [UUID: [Conversation]] = [:]
        var importedBySource: [String: [Conversation]] = [:]
        for conversation in filtered {
            if let accountID = conversation.accountID {
                grouped[accountID, default: []].append(conversation)
            } else {
                let key = conversation.importSourceJID ?? "Unknown"
                importedBySource[key, default: []].append(conversation)
            }
        }
        return (grouped, importedBySource)
    }

    var conversationsByAccount: [(account: Account, conversations: [Conversation])] {
        let grouped = partitionedConversations.byAccount
        return accounts.compactMap { account in
            guard let convs = grouped[account.id], !convs.isEmpty else { return nil }
            return (account, convs)
        }
    }

    var importedConversationsBySource: [(sourceJID: String, conversations: [Conversation])] {
        partitionedConversations.importedBySource
            .sorted { $0.key < $1.key }
            .map { (sourceJID: $0.key, conversations: $0.value) }
    }

    // MARK: - Actions

    func clearSelectionIfFiltered() async {
        if let selected = selectedConversation,
           !filteredConversations.contains(where: { $0.id == selected.id }) {
            await selectConversation(nil)
        }
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
            guard list == listRevision else { return }
            let conversations = try await environment.chatService.fetchAllConversations()
            guard bootstrap == bootstrapRevision, list == listRevision else { return }
            allConversations = conversations
        } catch {
            guard bootstrap == bootstrapRevision else { return }
            log.error("Failed to load transcripts: \(error)")
        }
    }

    private func invalidateSearch() {
        searchRevision += 1
        searchResults = []
        searchMatchDates = []
    }

    private func resetSelectionState() {
        messages = []
        notes = []
        positions = [:]
        scroller.reset(to: .oldest)
        messageDates = []
        messageDateCounts = [:]
        selectedDate = nil
        invalidateSearch()
        transcriptSearchText = ""
    }

    func selectConversation(_ conversation: Conversation?) async {
        selectionRevision += 1
        let revision = selectionRevision
        selectedConversation = conversation
        resetSelectionState()
        isLoadingDetail = conversation != nil
        guard let conversation else { return }
        await loadConversation(conversation, revision: revision)
    }

    private func loadConversation(_ conversation: Conversation, revision: Int) async {
        defer {
            if revision == selectionRevision { isLoadingDetail = false }
        }
        do {
            let dateCounts = try await environment.chatService.conversationMessageDateCounts(conversation.id)
            guard revision == selectionRevision else { return }
            messageDates = dateCounts.map(\.date)
            messageDateCounts = Dictionary(uniqueKeysWithValues: dateCounts)
            if let latestDate = messageDates.first {
                selectedDate = latestDate
                try await loadDay(latestDate, conversation: conversation, revision: revision)
            }
        } catch {
            guard revision == selectionRevision else { return }
            log.error("Failed to load conversation transcript: \(error)")
        }
    }

    // MARK: - Scoping

    private var appliedScopeGeneration = 0

    /// A refresh may update the sidebar, but only a resolved target can supersede detail work.
    /// A local selection made while the refresh awaits takes precedence over that scope.
    func applyScope(_ request: ScopeRequest) async {
        guard request.generation > appliedScopeGeneration else { return }
        appliedScopeGeneration = request.generation
        let selection = selectionRevision
        let refreshed = try? await environment.chatService.fetchAllConversations()
        guard request.generation == appliedScopeGeneration else { return }
        if let refreshed {
            listRevision += 1
            allConversations = refreshed
        }
        guard selection == selectionRevision,
              let match = allConversations.first(where: { request.ref.matches($0) }) else { return }
        await selectConversation(match)
    }

    func selectDate(_ date: Date?) async {
        selectionRevision += 1
        let revision = selectionRevision
        selectedDate = date
        messages = []
        notes = []
        positions = [:]
        scroller.reset(to: .oldest)
        isLoadingDetail = false
        guard let date, let conversation = selectedConversation else { return }
        isLoadingDetail = true
        defer {
            if revision == selectionRevision { isLoadingDetail = false }
        }
        do {
            try await loadDay(date, conversation: conversation, revision: revision)
        } catch {
            guard revision == selectionRevision else { return }
            log.error("Failed to load messages for date: \(error)")
        }
    }

    private func loadDay(_ date: Date, conversation: Conversation, revision: Int) async throws {
        let dateMessages = try await environment.chatService.fetchMessageHistory(for: conversation.id, on: date)
        // A transcript day is a UTC day, the span one transcript file covers.
        let dateNotes = await environment.chatService.fetchNotes(
            for: conversation.id, since: date, before: date.addingTimeInterval(24 * 60 * 60)
        )
        guard revision == selectionRevision else { return }
        messages = dateMessages
        notes = dateNotes
        positions = computeMessagePositions(timelineItems)
        scroller.reset(to: .oldest)
    }

    func performTranscriptSearch() async {
        searchRevision += 1
        let revision = searchRevision
        let query = transcriptSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let conversation = selectedConversation else {
            searchResults = []
            searchMatchDates = []
            return
        }
        do {
            let results = try await environment.chatService.searchTranscripts(query: query, conversationID: conversation.id, limit: 500)
            guard revision == searchRevision else { return }
            searchResults = Set(results.map(\.id))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            searchMatchDates = Set(results.map { calendar.startOfDay(for: $0.timestamp) })
        } catch {
            guard revision == searchRevision else { return }
            log.error("Failed to search transcripts: \(error)")
        }
    }
}
