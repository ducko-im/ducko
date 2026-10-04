import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    @Environment(ThemeEngine.self) private var theme
    /// Everything the bubble draws apart from the avatar. `windowState` is only for the avatar and the menu.
    let row: TranscriptRow.Message
    let isHovered: Bool
    let windowState: ChatWindowState

    private var message: ChatMessage {
        row.message
    }

    private var isGroupchatIncoming: Bool {
        message.type == "groupchat" && !message.isOutgoing
    }

    private var hasCodeBlock: Bool {
        message.styledBodySegments?.contains(where: \.isCodeBlock) == true
    }

    private var showAvatar: Bool {
        theme.current.showAvatars && !message.isOutgoing && theme.current.avatarPosition == .leading
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            if showAvatar {
                if row.position.isLastInGroup {
                    SenderAvatarView(windowState: windowState, nickname: message.fromJID)
                } else {
                    Color.clear
                        .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
                }
            }

            MessageContentView(
                message: message,
                isGroupchatIncoming: isGroupchatIncoming,
                isMetadataVisible: row.position.isLastInGroup || isHovered,
                actionSenderName: row.actionSenderName,
                loadsIncomingImagesOnSight: row.loadsIncomingImagesOnSight,
                transferStatus: row.transferStatus,
                header: {
                    if let replyQuote = row.replyQuote {
                        ReplyQuoteView(senderName: replyQuote.senderName, bodyPreview: replyQuote.previewText)
                    }
                },
                footer: {
                    if let linkPreview = row.linkPreview {
                        LinkPreviewCard(preview: linkPreview)
                    }
                }
            )

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        // Attachments, link previews and code blocks carry their own controls, which a combined element would hide from assistive tech.
        .accessibilityElement(children: message.attachments.isEmpty && row.linkPreview == nil && !hasCodeBlock ? .combine : .contain)
        .accessibilityIdentifier("message-bubble-\(message.id)")
        .contextMenu {
            MessageContextMenu(message: message, windowState: windowState)
        }
    }
}

/// The avatar beside an incoming row: the contact's in a one-to-one chat, the occupant's in a room.
struct SenderAvatarView: View {
    @Environment(ThemeEngine.self) private var theme
    let windowState: ChatWindowState
    let nickname: String

    var body: some View {
        if !windowState.isGroupchat, let contact = windowState.contact {
            AvatarView(contact: contact, size: theme.current.avatarSize)
        } else {
            ParticipantAvatarView(nickname: nickname, size: theme.current.avatarSize)
        }
    }
}
