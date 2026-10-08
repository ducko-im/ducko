import DuckoCore
import Foundation

/// Identifies a conversation for transcript scoping. `Conversation` identity spans
/// `id`, `accountID`, `jid`, `type`, `occupantNickname`, and `importSourceJID` — a MUC PM
/// opens as `room@conf/nick` but persists with `jid == room@conf`, `type == .chat`,
/// `occupantNickname == nick`, so matching on bare JID alone selects the wrong row (the
/// room, or the same JID on another account). Carries the resolved `conversationID` when
/// known; otherwise the full tuple is matched.
public struct ConversationRef: Sendable, Hashable {
    public var conversationID: UUID?
    public var accountID: UUID?
    public var jid: String
    public var type: Conversation.ConversationType
    public var occupantNickname: String?
    public var importSourceJID: String?

    public init(
        conversationID: UUID? = nil,
        accountID: UUID? = nil,
        jid: String,
        type: Conversation.ConversationType,
        occupantNickname: String? = nil,
        importSourceJID: String? = nil
    ) {
        self.conversationID = conversationID
        self.accountID = accountID
        self.jid = jid
        self.type = type
        self.occupantNickname = occupantNickname
        self.importSourceJID = importSourceJID
    }

    public init(conversation: Conversation) {
        self.init(
            conversationID: conversation.id,
            accountID: conversation.accountID,
            jid: conversation.jid.description,
            type: conversation.type,
            occupantNickname: conversation.occupantNickname,
            importSourceJID: conversation.importSourceJID
        )
    }

    /// Prefers the open conversation so its `conversationID` scopes the history to that exact conversation.
    init(contact: Contact, openConversation: Conversation?) {
        if let openConversation {
            self.init(conversation: openConversation)
        } else {
            self.init(accountID: contact.accountID, jid: contact.jid.description, type: .chat)
        }
    }

    /// Matches a sidebar conversation: prefer `conversationID`, fall back to the full
    /// tuple — never bare JID alone (which mis-keys MUC PMs and cross-account duplicates).
    func matches(_ conversation: Conversation) -> Bool {
        if let conversationID { return conversation.id == conversationID }
        return conversation.accountID == accountID
            && conversation.jid.description == jid
            && conversation.type == type
            && conversation.occupantNickname == occupantNickname
            && conversation.importSourceJID == importSourceJID
    }
}

/// A scoping request bundled with a monotonic generation token so rapid successive
/// opens don't overwrite each other and a stale async handler can't clear or apply a
/// newer request.
public struct ScopeRequest: Sendable, Hashable {
    public var generation: Int
    public var ref: ConversationRef

    public init(generation: Int, ref: ConversationRef) {
        self.generation = generation
        self.ref = ref
    }
}

/// App-level shared selection that scopes the singleton history window to a conversation.
/// Other windows retarget the one history window through it rather than opening a window per conversation.
@MainActor @Observable
public final class TranscriptScope {
    public private(set) var requested: ScopeRequest?
    private var nextGeneration = 0

    public init() {}

    /// Records a scoped request with a fresh generation token and returns it.
    @discardableResult
    public func request(_ ref: ConversationRef) -> ScopeRequest {
        nextGeneration += 1
        let request = ScopeRequest(generation: nextGeneration, ref: ref)
        requested = request
        return request
    }

    /// Clears the request only when its generation matches the one actually handled, so a
    /// stale handler finishing late can't drop a newer request.
    public func clearHandled(_ generation: Int) {
        if requested?.generation == generation {
            requested = nil
        }
    }
}
