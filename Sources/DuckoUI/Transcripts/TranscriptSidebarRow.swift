import DuckoCore
import SwiftUI

struct TranscriptSidebarRow: View {
    let conversation: Conversation
    let title: String
    let avatarData: Data?

    var body: some View {
        HStack {
            ConversationAvatarView(conversation: conversation, title: title, avatarData: avatarData)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .singleLine()

                if title != conversation.jid.description {
                    Text(conversation.jid.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                }
            }
        }
    }
}
