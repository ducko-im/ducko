import DuckoCore
import SwiftUI

/// Stands at the end of the timeline for a file the contact is sending right now, looking like the message that will
/// replace it once the file is saved.
struct ReceivingFileRow: View {
    @Environment(ThemeEngine.self) private var theme
    let transfer: FileTransferService.ActiveTransfer
    let windowState: ChatWindowState

    /// Shares the transfer's id, which is how its status line finds the transfer.
    private var placeholder: ChatMessage {
        ChatMessage(
            id: transfer.id,
            conversationID: windowState.conversation?.id ?? transfer.id,
            fromJID: windowState.jidString,
            body: "",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [Attachment(id: transfer.id, url: "", fileName: transfer.fileName, fileSize: transfer.fileSize)]
        )
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if theme.current.showAvatars, theme.current.avatarPosition == .leading {
                SenderAvatarView(windowState: windowState, nickname: windowState.jidString)
            }

            MessageContentView(
                message: placeholder,
                isGroupchatIncoming: false,
                isMetadataVisible: false,
                actionSenderName: windowState.displayName,
                loadsIncomingImagesOnSight: false
            )

            Spacer(minLength: 60)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receiving-file-row")
    }
}
