import Foundation

public struct TranscriptAmendment: Sendable {
    public enum Action: String, Sendable, Codable {
        case edit, retract, delivery, displayed, error
    }

    public var action: Action
    /// Locally-resolved message UUID; preferred over `targetStanzaID`,
    /// which collides within a per-day JSONL file when MAM-imported
    /// `ducko-N` counters repeat. Optional for back-compat with older
    /// records and carbon/MAM paths that only know the stanzaID.
    public var targetMessageID: UUID?
    public var targetStanzaID: String?
    public var targetServerID: String?
    public var timestamp: Date
    public var body: String?
    public var htmlBody: String?
    public var errorText: String?

    public init(
        action: Action,
        targetMessageID: UUID? = nil,
        targetStanzaID: String? = nil,
        targetServerID: String? = nil,
        timestamp: Date = Date(),
        body: String? = nil,
        htmlBody: String? = nil,
        errorText: String? = nil
    ) {
        self.action = action
        self.targetMessageID = targetMessageID
        self.targetStanzaID = targetStanzaID
        self.targetServerID = targetServerID
        self.timestamp = timestamp
        self.body = body
        self.htmlBody = htmlBody
        self.errorText = errorText
    }
}
