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

func searchHistory(
    jid: BareJID, query: String, limit: Int,
    environment: AppEnvironment, accountID: UUID
) async throws -> [ChatMessage] {
    guard let conversation = try await resolveConversation(jid: jid, environment: environment, accountID: accountID) else {
        return []
    }
    return try await environment.chatService.searchMessages(for: conversation.id, query: query, limit: limit)
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
