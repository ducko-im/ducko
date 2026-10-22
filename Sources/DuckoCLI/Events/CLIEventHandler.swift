import DuckoCore
import DuckoXMPP
import Foundation

actor CLIEventHandler {
    private let formatter: any CLIFormatter
    private let isInteractive: Bool

    init(formatter: any CLIFormatter, isInteractive: Bool = false) {
        self.formatter = formatter
        self.isInteractive = isInteractive
    }

    func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .messageReceived(message):
            if message.hasClassifiedEvent { return }
            ringBell()
        case let .roomMessageReceived(message), let .mucPrivateMessageReceived(message):
            // An encrypted one prints and rings once stored, with its text or its notice.
            if message.isEncrypted { return }
            ringBell()
        case let .messageCarbonSent(forwarded), let .messageCarbonReceived(forwarded):
            // A retraction prints and rings nothing, and an encrypted one prints and rings once stored.
            if !printsFromEvent(carbon: forwarded.message) { return }
            ringBell()
        case .roomInviteReceived,
             .jingleFileTransferReceived,
             .oobIQOfferReceived:
            ringBell()
        case let .chatStateChanged(from, state, messageType):
            // A room's occupant is named by the nickname in its address, as its room lines are; a contact by its bare address.
            let typist: JID = messageType == .groupchat ? from : .bare(from.bareJID)
            handleChatState(from: typist, state: state)
            return
        case .jingleFileTransferProgress,
             .omemoDeviceListReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            guard isInteractive else { break }
        case .connected, .streamResumed, .disconnected, .authenticationFailed, .plainSignInRefused,
             .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .archivedMessagesLoaded,
             .deliveryReceiptReceived, .chatMarkerReceived,
             .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferCompleted, .jingleFileTransferFailed,
             .jingleChecksumReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             // An encrypted message is presented once it is stored (`handleEncryptedMessage`), so a copy already
             // stored neither prints nor rings.
             .omemoEncryptedMessageReceived, .omemoRecipientsPartial:
            break
        }
        guard let output = formatter.formatEvent(event, accountID: accountID) else { return }
        print(output)
    }

    func handleEncryptedMessage(_ message: ChatMessage, in conversation: Conversation, accountID: UUID) {
        ringBell()
        print(formatter.formatEncryptedMessage(message, in: conversation, accountID: accountID))
    }

    private func handleChatState(from: JID, state: ChatState) {
        guard isInteractive else { return }
        if let output = formatter.formatTypingIndicator(from: from, state: state) {
            print(output)
        }
    }

    private func ringBell() {
        if isInteractive, !(formatter is JSONFormatter) {
            print("\u{07}", terminator: "")
        }
    }
}
