import DuckoCore
import SwiftUI

/// Read-only message bubble for the transcript viewer.
/// Simplified variant of MessageBubbleView without reply/edit/retract actions.
struct TranscriptBubbleView: View {
    let row: TranscriptRow.Message

    private var message: ChatMessage {
        row.message
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            MessageContentView(
                message: message,
                isGroupchatIncoming: row.isGroupchat && !message.isOutgoing,
                isMetadataVisible: row.position.isLastInGroup,
                actionSenderName: row.actionSenderName,
                loadsIncomingImagesOnSight: row.loadsIncomingImagesOnSight,
                transferStatus: row.transferStatus
            )
            .contextMenu {
                if !message.isRetracted, !message.isUndecryptable {
                    Button(message.bodyIsAttachmentLink ? "Copy Link" : "Copy Text") {
                        copyToPasteboard(message.body)
                    }
                }
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .messageRowFrame(row)
    }
}
