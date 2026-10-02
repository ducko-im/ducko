import DuckoCore
import SwiftUI

/// Read-only message bubble for the transcript viewer.
/// Simplified variant of MessageBubbleView without reply/edit/retract actions.
struct TranscriptBubbleView: View {
    let message: ChatMessage
    let position: MessagePosition
    let isGroupchat: Bool
    let isSearchResult: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            MessageContentView(
                message: message,
                isGroupchatIncoming: isGroupchat && !message.isOutgoing,
                isMetadataVisible: position.isLastInGroup,
                actionSenderName: message.fromJID,
                loadsIncomingImagesOnSight: false
            )
            .contextMenu {
                if !message.isRetracted, !message.isUndecryptable {
                    Button(message.bodyIsAttachmentLink ? "Copy Link" : "Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.body, forType: .string)
                    }
                }
            }

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        .padding(.top, position.isFirstInGroup ? 8 : 2)
        .padding(.horizontal)
        .background(
            isSearchResult ? Color.yellow.opacity(0.15) : Color.clear,
            in: .rect(cornerRadius: 8)
        )
    }
}
