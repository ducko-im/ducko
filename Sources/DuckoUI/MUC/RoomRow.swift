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

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(display: display)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.displayTitle)
                    .fontWeight(.medium)
                    .lineLimit(1)

                switch caption {
                case let .subject(subject):
                    Text(subject)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case let .participants(count):
                    Text("\(count) participants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .none:
                    EmptyView()
                }
            }

            Spacer()

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    // A compact row is as tall as the name's line, which the badge has to stay within.
                    .padding(.vertical, isCompact ? 1 : 2)
                    .background(.red, in: .capsule)
            }

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
        .accessibilityIdentifier("room-row-\(conversation.jid)")
    }
}
