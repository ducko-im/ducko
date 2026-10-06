import DuckoCore
import SwiftUI

struct TranscriptSidebarRow: View {
    let conversation: Conversation

    var body: some View {
        HStack {
            Image(systemName: conversation.type == .groupchat
                ? "bubble.left.and.bubble.right"
                : "bubble.left")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .singleLine()

                if conversation.displayTitle != conversation.jid.description {
                    Text(conversation.jid.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                }
            }

            Spacer()

            if let date = conversation.lastMessageDate {
                Text(date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
