import DuckoCore
import DuckoXMPP
import Foundation

func parseBeforeDate(_ string: String?) throws -> Date? {
    guard let string else { return nil }
    let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    if let date = try? style.parse(string) {
        return date
    }
    let basicStyle = Date.ISO8601FormatStyle()
    if let date = try? basicStyle.parse(string) {
        return date
    }
    throw CLIError.invalidDate(string)
}

func fetchHistory(
    jid: BareJID, before: Date?, limit: Int,
    environment: AppEnvironment, accountID: UUID
) async throws -> [ChatMessage] {
    guard let conversation = try await resolveConversation(jid: jid, environment: environment, accountID: accountID) else {
        return []
    }
    return try await environment.chatService.fetchMessageHistory(for: conversation.id, before: before, limit: limit)
}

/// A chat's timeline notes, with the name they call the contact by.
struct HistoryNotes {
    let notes: [TimelineNote]
    let contactName: String
}

/// The timeline notes that belong among `messages`: those from the oldest message on, up to `before`.
func fetchHistoryNotes(
    jid: BareJID, among messages: [ChatMessage], before: Date?,
    environment: AppEnvironment, accountID: UUID
) async throws -> HistoryNotes {
    guard let conversation = try await resolveConversation(jid: jid, environment: environment, accountID: accountID) else {
        return HistoryNotes(notes: [], contactName: jid.description)
    }
    let notes = await environment.chatService.fetchNotes(for: conversation.id, since: messages.first?.timestamp, before: before)
    return HistoryNotes(notes: notes, contactName: jid.description)
}

/// One day of one conversation, with the messages a search found on it, oldest first.
struct HistorySearchDay {
    /// The conversation's address. A private chat in a room has the room's bare address, so it is named by its
    /// occupant's.
    let jid: JID
    let date: Date
    let messages: [ChatMessage]
}

/// The newest `limit` messages a search finds in the chat with `jid`, or in all the account's conversations when no
/// `jid` is given. They come by conversation and day, newest day first.
func searchHistory(
    jid: BareJID?, query: String, limit: Int,
    environment: AppEnvironment, accountID: UUID
) async throws -> [HistorySearchDay] {
    let conversations: [Conversation] = if let jid {
        try await [resolveConversation(jid: jid, environment: environment, accountID: accountID)].compactMap(\.self)
    } else {
        try await environment.chatService.fetchAllConversations().filter { $0.accountID == accountID }
    }
    let jids = Dictionary(conversations.map { ($0.id, searchAddress(of: $0)) }, uniquingKeysWith: { first, _ in first })
    let found = try await environment.chatService.searchTranscriptMessages(query: query, in: conversations.map(\.id), limit: limit)
    return found.compactMap { day, messages in
        jids[day.conversationID].map { HistorySearchDay(jid: $0, date: day.date, messages: oldestFirst(messages)) }
    }
}

private func searchAddress(of conversation: Conversation) -> JID {
    conversation.occupantNickname
        .flatMap { FullJID(bareJID: conversation.jid, resourcePart: $0) }
        .map(JID.full) ?? .bare(conversation.jid)
}

/// A day's messages come in the order they were stored, which an archive sync can leave out of time order. Messages
/// of one time keep the order they were stored in.
private func oldestFirst(_ messages: [ChatMessage]) -> [ChatMessage] {
    messages.enumerated()
        .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
        .map(\.element)
}

private func resolveConversation(
    jid: BareJID,
    environment: AppEnvironment,
    accountID: UUID
) async throws -> Conversation? {
    try await environment.chatService.loadConversations(for: accountID)
    let conversations = await MainActor.run { environment.chatService.openConversations }
    // Scope by account: `openConversations` is a cross-account union, so a bare-JID match alone could
    // resolve another account's conversation when the same peer is rostered on two accounts.
    return conversations.first(where: { $0.jid == jid && $0.accountID == accountID })
}

/// Prints a search's results. Those of all conversations name each day's conversation on a line before its messages.
/// Those of one conversation are its matches alone, oldest first.
func printSearchResults(
    _ days: [HistorySearchDay], ofAllConversations: Bool,
    formatter: any CLIFormatter, accountJID: BareJID
) {
    guard ofAllConversations, !days.isEmpty else {
        printHistory(days.reversed().flatMap(\.messages), formatter: formatter, accountJID: accountJID)
        return
    }
    for day in days {
        print(formatter.formatSearchDay(jid: day.jid, day: day.date, matchCount: day.messages.count))
        for message in day.messages {
            print(formatter.formatMessage(message, accountJID: accountJID))
        }
    }
}

func printHistory(
    _ messages: [ChatMessage], notes: HistoryNotes? = nil,
    formatter: any CLIFormatter, accountJID: BareJID? = nil
) {
    guard !messages.isEmpty || notes?.notes.isEmpty == false else {
        print(formatter.formatEmptyResult(.messages))
        return
    }
    for item in TimelineItem.merged(messages: messages, notes: notes?.notes ?? []) {
        switch item {
        case let .message(message): print(formatter.formatMessage(message, accountJID: accountJID))
        case let .note(note):
            guard let notes else { continue }
            print(formatter.formatNote(note, contactName: notes.contactName))
        }
    }
}
