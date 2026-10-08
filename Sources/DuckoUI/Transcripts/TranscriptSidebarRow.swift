import DuckoCore
import SwiftUI

struct TranscriptSidebarRow: View {
    let conversation: Conversation
    let avatarData: Data?

    var body: some View {
        HStack {
            ConversationAvatarView(conversation: conversation, avatarData: avatarData)

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
        }
    }
}
