import DuckoCore
import DuckoTestSupport
import Foundation

enum TranscriptRead: Hashable {
    case accounts
    case conversations
    case dates(UUID)
    case day(UUID, Date)
    case search(UUID?, String)
}

actor TranscriptReadGates {
    private var pending: [TranscriptRead: [TranscriptReadGate]] = [:]

    func suspendNext(_ read: TranscriptRead) -> TranscriptReadGate {
        let gate = TranscriptReadGate()
        pending[read, default: []].append(gate)
        return gate
    }

    func pause(_ read: TranscriptRead) async throws {
        guard var queue = pending[read], !queue.isEmpty else { return }
        let gate = queue.removeFirst()
        pending[read] = queue
        try await gate.pause()
    }
}

actor TranscriptReadGate {
    enum Failure: Error { case releasedWithError, timeout }

    private let arrival = AsyncStream.makeStream(of: Void.self)
    private let release = AsyncStream.makeStream(of: Bool.self)

    func pause() async throws {
        arrival.continuation.yield(())
        arrival.continuation.finish()
        for await failed in release.stream where failed {
            throw Failure.releasedWithError
        }
    }

    func open(failing: Bool = false) {
        release.continuation.yield(failing)
        release.continuation.finish()
    }

    func waitForArrival() async throws {
        let stream = arrival.stream
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                defer { group.cancelAll() }
                group.addTask { for await _ in stream {
                    return
                } }
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw Failure.timeout
                }
                try await group.next()
            }
        } catch {
            open(failing: true)
            throw error
        }
    }
}

struct GatedTranscriptStore: TranscriptStore {
    let mock = MockTranscriptStore()
    let gates: TranscriptReadGates

    func appendMessage(_ message: ChatMessage) async throws {
        try await mock.appendMessage(message)
    }

    func appendMessages(_ messages: [ChatMessage]) async throws {
        try await mock.appendMessages(messages)
    }

    func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws {
        try await mock.appendAmendment(amendment, conversationID: conversationID)
    }

    func appendNote(_ note: TimelineNote) async throws {
        try await mock.appendNote(note)
    }

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage] {
        try await mock.fetchMessages(for: conversationID, before: before, limit: limit)
    }

    func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage] {
        let result = try await mock.fetchMessages(for: conversationID, on: date)
        try await gates.pause(.day(conversationID, date))
        return result
    }

    func fetchNotes(for conversationID: UUID, since: Date?, before: Date?) async throws -> [TimelineNote] {
        try await mock.fetchNotes(for: conversationID, since: since, before: before)
    }

    func findMessage(id: UUID, conversationID: UUID) async throws -> ChatMessage? {
        try await mock.findMessage(id: id, conversationID: conversationID)
    }

    func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage? {
        try await mock.findMessage(stanzaID: stanzaID, conversationID: conversationID)
    }

    func findMessages(stanzaID: String, conversationID: UUID) async throws -> [ChatMessage] {
        try await mock.findMessages(stanzaID: stanzaID, conversationID: conversationID)
    }

    func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool {
        try await mock.messageExists(stanzaID: stanzaID, conversationID: conversationID)
    }

    func messageExists(serverID: String, conversationID: UUID) async throws -> Bool {
        try await mock.messageExists(serverID: serverID, conversationID: conversationID)
    }

    func messageExists(stanzaID: String, fromJID: String, conversationID: UUID) async throws -> Bool {
        try await mock.messageExists(stanzaID: stanzaID, fromJID: fromJID, conversationID: conversationID)
    }

    func searchMessages(query: String, conversationID: UUID?, before: Date?, after: Date?, limit: Int) async throws -> [ChatMessage] {
        let result = try await mock.searchMessages(query: query, conversationID: conversationID, before: before, after: after, limit: limit)
        try await gates.pause(.search(conversationID, query))
        return result
    }

    func messageDateCounts(for conversationID: UUID) async throws -> [(date: Date, count: Int)] {
        let result = try await mock.messageDateCounts(for: conversationID)
        try await gates.pause(.dates(conversationID))
        return result
    }

    func deleteTranscripts(for conversationID: UUID) async throws {
        try await mock.deleteTranscripts(for: conversationID)
    }

    func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws {
        try await mock.writeMetadata(metadata, for: conversationID)
    }
}

struct GatedTranscriptPersistenceStore: PersistenceStore {
    let mock = MockPersistenceStore()
    let gates: TranscriptReadGates

    func applyRosterMutation(_ mutation: RosterMutation) async throws -> [Contact] {
        try await mock.applyRosterMutation(mutation)
    }

    func updateContactIfExists(_ id: UUID, accountID: UUID, update: ContactMetadataUpdate) async throws -> Bool {
        try await mock.updateContactIfExists(id, accountID: accountID, update: update)
    }

    func fetchAccounts() async throws -> [Account] {
        let result = try await mock.fetchAccounts()
        try await gates.pause(.accounts)
        return result
    }

    func saveAccount(_ account: Account) async throws {
        try await mock.saveAccount(account)
    }

    func deleteAccount(_ id: UUID) async throws {
        try await mock.deleteAccount(id)
    }

    func fetchContacts(for accountID: UUID) async throws -> [Contact] {
        try await mock.fetchContacts(for: accountID)
    }

    func upsertContact(_ contact: Contact) async throws {
        try await mock.upsertContact(contact)
    }

    func deleteContact(_ id: UUID) async throws {
        try await mock.deleteContact(id)
    }

    func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        try await mock.fetchConversations(for: accountID)
    }

    func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) async throws -> Conversation? {
        try await mock.fetchConversation(jid: jid, type: type, accountID: accountID, importSourceJID: importSourceJID)
    }

    func fetchConversations(importSourceJID: String) async throws -> [Conversation] {
        try await mock.fetchConversations(importSourceJID: importSourceJID)
    }

    func upsertConversation(_ conversation: Conversation) async throws {
        try await mock.upsertConversation(conversation)
    }

    func updateConversation(_ conversationID: UUID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation? {
        try await mock.updateConversation(conversationID, change)
    }

    func fetchAllConversations() async throws -> [Conversation] {
        let result = try await mock.fetchAllConversations()
        try await gates.pause(.conversations)
        return result
    }

    func markConversationRead(_ conversationID: UUID) async throws {
        try await mock.markConversationRead(conversationID)
    }

    func deleteConversation(_ conversationID: UUID) async throws {
        try await mock.deleteConversation(conversationID)
    }

    func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) async throws {
        try await mock.unlinkConversations(for: accountID, restoreImportSourceJID: restoreImportSourceJID)
    }

    func deleteConversations(for accountID: UUID) async throws {
        try await mock.deleteConversations(for: accountID)
    }

    func deleteContacts(for accountID: UUID) async throws {
        try await mock.deleteContacts(for: accountID)
    }

    func fetchLinkPreview(for url: String) async throws -> LinkPreview? {
        try await mock.fetchLinkPreview(for: url)
    }

    func upsertLinkPreview(_ preview: LinkPreview) async throws {
        try await mock.upsertLinkPreview(preview)
    }
}
