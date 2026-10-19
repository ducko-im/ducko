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
        case .messageCarbonReceived, .messageCarbonSent,
             .roomMessageReceived, .mucPrivateMessageReceived, .roomInviteReceived,
             .jingleFileTransferReceived,
             .oobIQOfferReceived:
            ringBell()
        case let .chatStateChanged(from, state):
            handleChatState(from: from, state: state)
            return
        case .jingleFileTransferProgress,
             .omemoDeviceListReceived, .omemoSessionEstablished, .omemoSessionAdvanced:
            guard isInteractive else { break }
        case .connected, .streamResumed, .disconnected, .authenticationFailed,
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
             .omemoEncryptedMessageReceived, .omemoRecipientsPartial,
             .serviceOutageReceived:
            break
        }
        guard let output = formatter.formatEvent(event, accountID: accountID) else { return }
        print(output)
    }

    func handleEncryptedMessage(_ message: ChatMessage, accountID: UUID) {
        ringBell()
        print(formatter.formatEncryptedMessage(message, accountID: accountID))
    }

    private func handleChatState(from: BareJID, state: ChatState) {
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
