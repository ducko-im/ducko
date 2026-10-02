import Foundation

public struct ChatMessage: Sendable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var stanzaID: String?
    public var serverID: String?
    public var fromJID: String
    public var body: String
    public var htmlBody: String?
    public var timestamp: Date
    public var isOutgoing: Bool
    public var isDelivered: Bool
    public var isEdited: Bool
    public var editedAt: Date?
    public var type: String
    public var replyToID: String?
    public var errorText: String?
    public var isRetracted: Bool
    public var retractedAt: Date?
    public var isEncrypted: Bool
    /// An encrypted message this device could not decrypt. It has no body: what it shows is `undecryptableText`.
    public var isUndecryptable: Bool
    public var attachments: [Attachment]

    public init(
        id: UUID,
        conversationID: UUID,
        stanzaID: String? = nil,
        serverID: String? = nil,
        fromJID: String,
        body: String,
        htmlBody: String? = nil,
        timestamp: Date,
        isOutgoing: Bool,
        isDelivered: Bool,
        isEdited: Bool,
        editedAt: Date? = nil,
        type: String,
        replyToID: String? = nil,
        errorText: String? = nil,
        isRetracted: Bool = false,
        retractedAt: Date? = nil,
        isEncrypted: Bool = false,
        isUndecryptable: Bool = false,
        attachments: [Attachment] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.stanzaID = stanzaID
        self.serverID = serverID
        self.fromJID = fromJID
        self.body = body
        self.htmlBody = htmlBody
        self.timestamp = timestamp
        self.isOutgoing = isOutgoing
        self.isDelivered = isDelivered
        self.isEdited = isEdited
        self.editedAt = editedAt
        self.type = type
        self.replyToID = replyToID
        self.errorText = errorText
        self.isRetracted = isRetracted
        self.retractedAt = retractedAt
        self.isEncrypted = isEncrypted
        self.isUndecryptable = isUndecryptable
        self.attachments = attachments
    }

    public static let undecryptableText = "This message could not be decrypted"

    /// What the message reads as wherever one line stands for it — a conversation's last-message preview, a
    /// notification. A received file arrives with no text, so the file's name is what it says.
    public var previewText: String {
        if isUndecryptable { return Self.undecryptableText }
        return body.isEmpty ? attachments.first?.displayFileName ?? "" : body
    }

    /// Whether the body only repeats an attachment's link, as a shared file's message does, so the attachment stands
    /// for the text.
    public var bodyIsAttachmentLink: Bool {
        attachments.areLinked(by: body)
    }

    /// Creates a display-only message for CLI output formatting.
    public static func displayPlaceholder(
        fromJID: String,
        body: String,
        type: String = "chat",
        replyToID: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            conversationID: UUID(),
            fromJID: fromJID,
            body: body,
            timestamp: Date(),
            isOutgoing: true,
            isDelivered: false,
            isEdited: false,
            type: type,
            replyToID: replyToID
        )
    }
}
