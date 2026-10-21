import DuckoXMPP
import Foundation

extension ChatService {
    /// When a live `message` was sent: the time a delay stamped by the account's server or the message's room names,
    /// else now.
    func sentTime(of message: XMPPMessage, accountID: UUID) -> Date {
        delayStamp(of: message, accountID: accountID)?.sentTime ?? Date()
    }

    func delayStamp(of message: XMPPMessage, accountID: UUID) -> DelayStamp? {
        DelayStamp(in: message, accountJID: resolvedAccountJID(for: accountID))
    }

    /// When a live `message` of `room` was sent, and whether it is history the room replays on join. It is join history
    /// when the room stamped it and the room's subject, which ends the history, has not come yet. A room stamps only
    /// the history it replays, so only then does its delay name when the message was sent. Read before the first wait,
    /// because the subject can be handled meanwhile.
    func roomArrival(of message: XMPPMessage, in room: BareJID, accountID: UUID) -> (sentTime: Date, isJoinHistory: Bool) {
        let delay = delayStamp(of: message, accountID: accountID)
        let isJoinHistory = delay?.isFromRoom == true && roomService.isReplayingHistory(in: room, accountID: accountID)
        guard let delay, !delay.isFromRoom || isJoinHistory else { return (Date(), isJoinHistory) }
        return (delay.sentTime, isJoinHistory)
    }
}
