import DuckoCore
import Foundation

/// The optional caption line a `RoomRow` shows beneath the room's title. One
/// source of truth for the per-branch precedence so the row view (which renders
/// the text) and the contact-list height memo (which only needs `hasSecondLine`)
/// derive it identically — keeping the measured row height in lockstep with what
/// actually renders.
enum RoomCaption: Equatable {
    case subject(String)
    case participants(Int)
    case none

    var hasSecondLine: Bool {
        self != .none
    }

    /// Convenience reading the live participant count, matching what `RoomRow`
    /// renders against (zero when the room has no bound account).
    @MainActor
    static func resolve(for conversation: Conversation, isCompact: Bool, chatService: ChatService) -> RoomCaption {
        resolve(roomSubject: conversation.roomSubject, participantCount: participantCount(for: conversation, chatService: chatService), isCompact: isCompact)
    }

    /// The one derivation of a room's occupant count, shared by the row and the contact-list height memo so they cannot
    /// disagree about whether the room is joined.
    @MainActor
    static func participantCount(for conversation: Conversation, chatService: ChatService) -> Int {
        conversation.accountID.map {
            chatService.participantCount(forRoomJIDString: conversation.jid.description, accountID: $0)
        } ?? 0
    }

    static func resolve(roomSubject: String?, participantCount: Int, isCompact: Bool) -> RoomCaption {
        guard !isCompact else { return .none }
        if let subject = roomSubject, !subject.isEmpty {
            return .subject(subject)
        }
        if participantCount > 0 {
            return .participants(participantCount)
        }
        return .none
    }
}
