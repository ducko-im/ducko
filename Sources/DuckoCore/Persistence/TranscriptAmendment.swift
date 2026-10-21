import Foundation

public struct TranscriptAmendment: Sendable {
    public enum Action: String, Sendable, Codable {
        case edit, retract, delivery, displayed, error
        /// Fills in the text of a message stored as undecryptable, once another copy of it was decrypted.
        case decrypted
        /// Records `serverID` on a message stored before the server assigned one, such as the user's own room message
        /// once the room echoes it.
        case serverIDAssigned
    }

    public var action: Action
    /// Locally-resolved message UUID; preferred over `targetStanzaID`,
    /// which collides within a per-day JSONL file when two senders
    /// use the same stanza ID. Optional for back-compat with older
    /// records and carbon/MAM paths that only know the stanzaID.
    public var targetMessageID: UUID?
    public var targetStanzaID: String?
    public var targetServerID: String?
    public var timestamp: Date
    public var body: String?
    public var htmlBody: String?
    /// The part of an `edit`'s or `decrypted`'s body that quotes the message a reply answers. Nil clears it.
    public var replyFallbackRange: Range<Int>?
    /// The message a `decrypted` one replies to, which only its encryption names.
    public var replyToID: String?
    public var replyToJID: String?
    /// The files a `decrypted` message carries, which only its encryption names.
    public var attachments: [Attachment]?
    public var errorText: String?
    /// The server ID a `serverIDAssigned` amendment records.
    public var serverID: String?

    public init(
        action: Action,
        targetMessageID: UUID? = nil,
        targetStanzaID: String? = nil,
        targetServerID: String? = nil,
        timestamp: Date = Date(),
        body: String? = nil,
        htmlBody: String? = nil,
        replyFallbackRange: Range<Int>? = nil,
        replyToID: String? = nil,
        replyToJID: String? = nil,
        attachments: [Attachment]? = nil,
        errorText: String? = nil,
        serverID: String? = nil
    ) {
        self.action = action
        self.targetMessageID = targetMessageID
        self.targetStanzaID = targetStanzaID
        self.targetServerID = targetServerID
        self.timestamp = timestamp
        self.body = body
        self.htmlBody = htmlBody
        self.replyFallbackRange = replyFallbackRange
        self.replyToID = replyToID
        self.replyToJID = replyToJID
        self.attachments = attachments
        self.errorText = errorText
        self.serverID = serverID
    }
}

package extension TranscriptAmendment {
    /// Fills in `placeholder`, stored as undecryptable, from `copy`, a decrypted copy of the same message.
    static func decrypted(_ placeholder: ChatMessage, as copy: ChatMessage) -> TranscriptAmendment {
        TranscriptAmendment(
            action: .decrypted, targetMessageID: placeholder.id, timestamp: Date(), body: copy.body, htmlBody: copy.htmlBody,
            replyFallbackRange: copy.replyFallbackRange, replyToID: copy.replyToID, replyToJID: copy.replyToJID,
            attachments: copy.attachments
        )
    }
}

package extension ChatMessage {
    mutating func apply(_ amendment: TranscriptAmendment) {
        switch amendment.action {
        case .edit:
            // A correction older than the one applied already, such as one read from the archive later, is stale.
            guard let body = amendment.body, editedAt.map({ amendment.timestamp >= $0 }) ?? true else { return }
            self.body = body
            htmlBody = amendment.htmlBody
            replyFallbackRange = amendment.replyFallbackRange
            isEdited = true
            editedAt = amendment.timestamp
        case .retract:
            isRetracted = true
            retractedAt = amendment.timestamp
            body = ""
            htmlBody = nil
        case .delivery:
            isDelivered = true
        case .displayed:
            isDelivered = true
            isDisplayed = true
        case .error:
            errorText = amendment.errorText
        case .decrypted:
            applyDecrypted(amendment)
        case .serverIDAssigned:
            guard serverID == nil else { return }
            serverID = amendment.serverID
        }
    }

    /// Applies a `decrypted` amendment, so the message reads as its decrypted copy. A retraction keeps it gone, and a
    /// correction's text is the newer one.
    private mutating func applyDecrypted(_ amendment: TranscriptAmendment) {
        isUndecryptable = false
        undecryptableReason = nil
        guard !isRetracted else { return }
        replyToID = amendment.replyToID
        replyToJID = amendment.replyToJID
        attachments = amendment.attachments ?? []
        guard !isEdited else { return }
        body = amendment.body ?? ""
        htmlBody = amendment.htmlBody
        replyFallbackRange = amendment.replyFallbackRange
    }
}
