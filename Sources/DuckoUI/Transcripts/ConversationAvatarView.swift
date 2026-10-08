import DuckoCore
import SwiftUI

/// What stands for a conversation in chat history: the contact's photo or initials for a chat, the room symbol for a
/// room.
struct ConversationAvatarView: View {
    static let size: CGFloat = 24

    let conversation: Conversation
    let avatarData: Data?

    var body: some View {
        switch conversation.type {
        case .chat:
            AvatarView(imageData: avatarData, name: conversation.displayTitle, size: Self.size)
        case .groupchat:
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
        }
    }
}
