import Foundation
import SwiftData

@Model
final class AccountRecord {
    @Attribute(.unique) var id: UUID
    var jid: String
    var displayName: String?
    var isEnabled: Bool
    var connectOnLaunch: Bool
    var host: String?
    var port: Int?
    var resource: String?
    var requireTLS: Bool = true
    var rosterVersion: String?
    var certificateFingerprint: String?
    var requiresSCRAM = false
    /// The account's `[String: ChannelSearchLimit]`, JSON-encoded.
    var channelSearchLimits: Data?
    var importedFrom: String?
    @Relationship(deleteRule: .nullify, inverse: \ContactRecord.account)
    var contacts: [ContactRecord]
    @Relationship(deleteRule: .nullify, inverse: \ConversationRecord.account)
    var conversations: [ConversationRecord]
    var createdAt: Date

    init(
        id: UUID,
        jid: String,
        displayName: String? = nil,
        isEnabled: Bool = true,
        connectOnLaunch: Bool = false,
        host: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        requireTLS: Bool = true,
        rosterVersion: String? = nil,
        certificateFingerprint: String? = nil,
        requiresSCRAM: Bool = false,
        importedFrom: String? = nil,
        contacts: [ContactRecord] = [],
        conversations: [ConversationRecord] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.jid = jid
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.connectOnLaunch = connectOnLaunch
        self.host = host
        self.port = port
        self.resource = resource
        self.requireTLS = requireTLS
        self.rosterVersion = rosterVersion
        self.certificateFingerprint = certificateFingerprint
        self.requiresSCRAM = requiresSCRAM
        self.importedFrom = importedFrom
        self.contacts = contacts
        self.conversations = conversations
        self.createdAt = createdAt
    }
}
