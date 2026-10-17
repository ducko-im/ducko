import DuckoCore
import SwiftUI

struct ReplyComposeBar: View {
    let windowState: ChatWindowState

    var body: some View {
        if let replyingTo = windowState.replyingTo {
            composeRow(
                icon: "arrowshape.turn.up.left",
                label: replyLabel(for: replyingTo),
                preview: replyingTo.previewText
            )
        } else if let editing = windowState.editingMessage {
            composeRow(
                icon: "pencil",
                label: "Editing message",
                preview: editing.previewText
            )
        }
    }

    private func replyLabel(for message: ChatMessage) -> String {
        if message.isOutgoing {
            return "Replying to yourself"
        }
        let name = message.incomingSenderName(contactName: windowState.knownContact?.displayName)
        return "Replying to \(name)"
    }

    private func composeRow(icon: String, label: String, preview: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(joiningLines: label)
                    .font(.caption)
                    .bold()
                    .singleLine()

                Text(joiningLines: preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .singleLine()
            }

            Spacer()

            Button {
                windowState.cancelReplyOrEdit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.windowBackgroundColor))
        .accessibilityIdentifier("reply-compose-bar")
    }
}
