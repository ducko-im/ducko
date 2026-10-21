import Foundation

/// What `TranscriptStore.storeEncryptedMessage(_:fromArchive:)` did with an encrypted message.
public enum EncryptedMessageStoreOutcome: Sendable, Equatable {
    /// No copy was stored yet, so the message was appended.
    case inserted
    /// An undecryptable copy was stored under the same server id, and now shows the decrypted text.
    case upgraded(placeholderID: UUID, timestamp: Date)
    /// A copy was stored already, and nothing was written.
    case duplicate
}

public protocol TranscriptStore: Sendable {
    // MARK: - Write

    func appendMessage(_ message: ChatMessage) async throws
    func appendMessages(_ messages: [ChatMessage]) async throws
    func appendAmendment(_ amendment: TranscriptAmendment, conversationID: UUID) async throws
    func appendNote(_ note: TimelineNote) async throws
    /// Stores an encrypted message unless a copy of it is stored already. The lookup and the write happen in one step,
    /// so a live copy and its archived copy arriving at once cannot both be stored. A message with a server id is
    /// matched by it. A message without one is matched by its message id, scoped to the sender when it was received. An
    /// archived copy is also matched by message id against a stored row that has no server id. A readable copy fills in
    /// an undecryptable one with the same server id and direction.
    func storeEncryptedMessage(_ message: ChatMessage, fromArchive: Bool) async throws -> EncryptedMessageStoreOutcome

    // MARK: - Read

    func fetchMessages(for conversationID: UUID, before: Date?, limit: Int) async throws -> [ChatMessage]
    /// The messages of the UTC day `date` falls in, oldest first. Messages with the same timestamp keep the order they
    /// were stored in.
    func fetchMessages(for conversationID: UUID, on date: Date) async throws -> [ChatMessage]
    /// The notes stamped at or after `since` and before `before`, oldest first. A nil bound is open.
    func fetchNotes(for conversationID: UUID, since: Date?, before: Date?) async throws -> [TimelineNote]

    // MARK: - Lookup

    /// Locates a message by locally-assigned UUID. Unlike `findMessage(stanzaID:)`,
    /// the UUID is unique per persisted message, while a stanza ID is unique only per sender and can
    /// recur across senders.
    func findMessage(id: UUID, conversationID: UUID) async throws -> ChatMessage?
    func findMessage(stanzaID: String, conversationID: UUID) async throws -> ChatMessage?
    /// All messages sharing `stanzaID` within the conversation. Unlike `findMessage(stanzaID:)`
    /// (first match only), this returns every match across date files so callers can disambiguate
    /// stanza ID collisions. Implementations must perform a full multi-file scan, not the
    /// single-valued stanza-index fast path.
    func findMessages(stanzaID: String, conversationID: UUID) async throws -> [ChatMessage]
    /// Locates a message by the server ID it was stored with or had recorded later by a `serverIDAssigned` amendment.
    func findMessage(serverID: String, conversationID: UUID) async throws -> ChatMessage?
    func messageExists(stanzaID: String, conversationID: UUID) async throws -> Bool
    func messageExists(serverID: String, conversationID: UUID) async throws -> Bool
    /// XEP-0359 stanza-id values are unique only *per sender*, so callers that
    /// dedup inbound stanzas must scope the lookup by `fromJID`. Otherwise an
    /// old archived outgoing message from this account with a colliding
    /// `stanzaID` (e.g. CLI counter resets across processes) would mark a
    /// fresh incoming message as duplicate and silently drop it.
    func messageExists(stanzaID: String, fromJID: String, conversationID: UUID) async throws -> Bool

    // MARK: - Days

    /// The days the conversation has stored history for, each as the start of its UTC day, newest first.
    func transcriptDays(for conversationID: UUID) async throws -> [Date]
    /// The messages of one day that `ChatMessage.matchesSearch(_:)` finds for `query`, in the order
    /// `fetchMessages(for:on:)` returns them.
    func matchingMessages(_ query: String, in conversationID: UUID, on day: Date) async throws -> [ChatMessage]

    // MARK: - Lifecycle

    func deleteTranscripts(for conversationID: UUID) async throws
    func writeMetadata(_ metadata: TranscriptMetadata, for conversationID: UUID) async throws
}

// MARK: - Default Implementations

public extension TranscriptStore {
    func appendMessages(_ messages: [ChatMessage]) async throws {
        for message in messages {
            try await appendMessage(message)
        }
    }
}
