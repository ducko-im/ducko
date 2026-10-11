import DuckoCore
import SwiftUI

struct RoomRow: View {
    @Environment(AppEnvironment.self) private var environment
    let conversation: Conversation
    let isCompact: Bool

    /// One lookup feeds both the ring and the caption, so a row cannot say it is joined in one place and not the other.
    private var participantCount: Int {
        RoomCaption.participantCount(for: conversation, chatService: environment.chatService)
    }

    private var caption: RoomCaption {
        RoomCaption.resolve(roomSubject: conversation.roomSubject, participantCount: participantCount, isCompact: isCompact)
    }

    private var display: ContactPresenceDisplay {
        ContactPresenceDisplay.resolve(isJoined: participantCount > 0)
    }

    private var activity: ConversationActivitySlot {
        ConversationActivitySlot(unreadCount: conversation.unreadCount, isTyping: false, resting: .presence(display))
    }

    var body: some View {
        let activity = activity
        HStack(spacing: 8) {
            // Laid out as wide as the dot, so the dot and name line up with the "me" header's bare dot.
            activity
                .padding(.horizontal, -ConversationActivitySlot.dotOverhang)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .fontWeight(.medium)
                    .singleLine()

                switch caption {
                case let .subject(subject):
                    Text(joiningLines: subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                case let .participants(count):
                    Text("\(count) participants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                case .none:
                    EmptyView()
                }
            }

            Spacer()

            // Rooms have no avatar, so the icon takes the avatar's place and keeps both kinds of row aligned.
            if !isCompact {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: AvatarView.defaultSize * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(width: AvatarView.defaultSize, height: AvatarView.defaultSize)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(activity.accessibilityDescription)
        .accessibilityIdentifier("room-row-\(conversation.jid)")
    }
}
