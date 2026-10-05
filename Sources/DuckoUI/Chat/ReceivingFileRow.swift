import DuckoCore
import SwiftUI

/// Stands at the end of the timeline for a file the contact is sending right now, looking like the message that will
/// replace it once the file is saved.
struct ReceivingFileRow: View {
    /// The transfer's id.
    let id: UUID
    let file: TranscriptRow.ReceivingFile
    let windowState: ChatWindowState

    private var placeholder: ChatMessage {
        ChatMessage(
            id: id,
            conversationID: windowState.conversation?.id ?? id,
            fromJID: windowState.jidString,
            body: "",
            timestamp: Date(),
            isOutgoing: false,
            isDelivered: false,
            isEdited: false,
            type: "chat",
            attachments: [Attachment(id: id, url: "", fileName: file.fileName, fileSize: file.fileSize)]
        )
    }

    var body: some View {
        HStack(alignment: .bottom) {
            SenderAvatarView(windowState: windowState, nickname: windowState.jidString)

            MessageContentView(
                message: placeholder,
                isGroupchatIncoming: false,
                isMetadataVisible: false,
                actionSenderName: windowState.displayName,
                loadsIncomingImagesOnSight: false,
                transferStatus: file.status
            )

            Spacer(minLength: 60)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("receiving-file-row")
    }
}
