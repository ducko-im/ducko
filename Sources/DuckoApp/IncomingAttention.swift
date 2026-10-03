import DuckoCore
import Foundation

/// What an incoming message or file offer does beyond landing in its chat.
struct IncomingAttention: Equatable {
    /// The chat gets a tab, and a chat window to show it in, without interrupting.
    var opensChatQuietly = false
    /// A notification is posted and the Dock icon bounces.
    var notifies = false

    /// Only a roster contact's message in a chat with them alone opens that chat: a stranger, a room and a room's
    /// occupant do not. `isInView` says the user is looking at the chat, which needs no notification.
    static func forMessage(
        _ message: ChatMessage, in conversation: Conversation, isFromRosterContact: Bool, isInView: Bool
    ) -> IncomingAttention {
        guard !conversation.isMuted else { return IncomingAttention() }
        return IncomingAttention(
            opensChatQuietly: !message.isOutgoing && conversation.isDirectChat && isFromRosterContact,
            notifies: !isInView
        )
    }

    /// `conversation` is the chat with the offer's sender, when there is one yet.
    static func forFileOffer(in conversation: Conversation?, isFromRosterContact: Bool, isInView: Bool) -> IncomingAttention {
        guard conversation?.isMuted != true else { return IncomingAttention() }
        return IncomingAttention(opensChatQuietly: isFromRosterContact, notifies: !isInView)
    }

    /// The chat with a file offer's sender alone, when there is one yet. A room and a private chat with one of its
    /// occupants share the sender's address and are not it.
    static func chat(withSender jidString: String, accountID: UUID, among conversations: [Conversation]) -> Conversation? {
        conversations.first { $0.isDirectChat && $0.jid.description == jidString && $0.accountID == accountID }
    }

    /// Who a notification says it is from: the chat's own name, else the sender's name in the roster, which is how
    /// the chat window names them, else the chat's short title, else the sender's address.
    static func senderName(in conversation: Conversation?, rosterName: String?, jidString: String) -> String {
        conversation?.displayName ?? rosterName ?? conversation?.displayTitle ?? jidString
    }
}
