import Foundation

/// A single line in a `.jsonl` transcript file: a message, an amendment to one, or a timeline note.
enum TranscriptRecord: Codable {
    case message(MessageEntry)
    case amendment(AmendmentEntry)
    case note(NoteEntry)

    // MARK: - Message Entry

    struct MessageEntry: Codable {
        var id: UUID
        var stanzaID: String?
        var serverID: String?
        var fromJID: String
        var body: String
        var htmlBody: String?
        var timestamp: Date
        var isOutgoing: Bool
        var isEncrypted: Bool
        /// Optional so records written before the flag existed decode. Those carry no key at all.
        var isUndecryptable: Bool?
        var messageType: String
        var replyToID: String?
        var attachments: [Attachment]
    }

    // MARK: - Amendment Entry

    struct AmendmentEntry: Codable {
        var action: TranscriptAmendment.Action
        var targetMessageID: UUID?
        var targetStanzaID: String?
        var targetServerID: String?
        var timestamp: Date?
        var body: String?
        var htmlBody: String?
        var errorText: String?
    }

    // MARK: - Note Entry

    struct NoteEntry: Codable {
        var id: UUID
        var timestamp: Date
        var kind: TimelineNote.Kind
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "msg":
            self = try .message(MessageEntry(from: decoder))
        case "amend":
            self = try .amendment(AmendmentEntry(from: decoder))
        case "note":
            self = try .note(NoteEntry(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [CodingKeys.type], debugDescription: "Unknown record type: \(type)")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .message(entry):
            try container.encode("msg", forKey: .type)
            try entry.encode(to: encoder)
        case let .amendment(entry):
            try container.encode("amend", forKey: .type)
            try entry.encode(to: encoder)
        case let .note(entry):
            try container.encode("note", forKey: .type)
            try entry.encode(to: encoder)
        }
    }

    // MARK: - Domain Conversion

    static func from(_ message: ChatMessage) -> TranscriptRecord {
        .message(MessageEntry(
            id: message.id,
            stanzaID: message.stanzaID,
            serverID: message.serverID,
            fromJID: message.fromJID,
            body: message.body,
            htmlBody: message.htmlBody,
            timestamp: message.timestamp,
            isOutgoing: message.isOutgoing,
            isEncrypted: message.isEncrypted,
            isUndecryptable: message.isUndecryptable,
            messageType: message.type,
            replyToID: message.replyToID,
            attachments: message.attachments
        ))
    }

    static func from(_ amendment: TranscriptAmendment) -> TranscriptRecord {
        .amendment(AmendmentEntry(
            action: amendment.action,
            targetMessageID: amendment.targetMessageID,
            targetStanzaID: amendment.targetStanzaID,
            targetServerID: amendment.targetServerID,
            timestamp: amendment.timestamp,
            body: amendment.body,
            htmlBody: amendment.htmlBody,
            errorText: amendment.errorText
        ))
    }

    static func from(_ note: TimelineNote) -> TranscriptRecord {
        .note(NoteEntry(id: note.id, timestamp: note.timestamp, kind: note.kind))
    }

    /// What a failed decrypt was recorded as before the flag existed: an encrypted message with this sentence as its
    /// body.
    private static let undecryptableBodyBeforeFlag = "Could not decrypt this message"

    func toChatMessage(conversationID: UUID) -> ChatMessage? {
        guard case let .message(entry) = self else { return nil }
        let isUndecryptable = entry.isUndecryptable ?? (entry.isEncrypted && entry.body == Self.undecryptableBodyBeforeFlag)
        return ChatMessage(
            id: entry.id,
            conversationID: conversationID,
            stanzaID: entry.stanzaID,
            serverID: entry.serverID,
            fromJID: entry.fromJID,
            body: isUndecryptable ? "" : entry.body,
            htmlBody: entry.htmlBody,
            timestamp: entry.timestamp,
            isOutgoing: entry.isOutgoing,
            isDelivered: false,
            isEdited: false,
            type: entry.messageType,
            replyToID: entry.replyToID,
            isEncrypted: entry.isEncrypted,
            isUndecryptable: isUndecryptable,
            attachments: entry.attachments
        )
    }

    func toNote(conversationID: UUID) -> TimelineNote? {
        guard case let .note(entry) = self else { return nil }
        return TimelineNote(id: entry.id, conversationID: conversationID, timestamp: entry.timestamp, kind: entry.kind)
    }

    func toAmendment() -> TranscriptAmendment? {
        guard case let .amendment(entry) = self else { return nil }
        return TranscriptAmendment(
            action: entry.action,
            targetMessageID: entry.targetMessageID,
            targetStanzaID: entry.targetStanzaID,
            targetServerID: entry.targetServerID,
            timestamp: entry.timestamp ?? Date(),
            body: entry.body,
            htmlBody: entry.htmlBody,
            errorText: entry.errorText
        )
    }
}
