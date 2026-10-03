import DuckoCore
import SwiftUI

struct MessageBubbleView: View {
    @Environment(ThemeEngine.self) private var theme
    let message: ChatMessage
    let position: MessagePosition
    let isHovered: Bool
    let repliedMessage: ChatMessage?
    let windowState: ChatWindowState

    private var isGroupchatIncoming: Bool {
        message.type == "groupchat" && !message.isOutgoing
    }

    private var actionSenderName: String {
        if message.isOutgoing {
            return "You"
        }
        if isGroupchatIncoming {
            return message.fromJID
        }
        return windowState.contact?.displayName ?? message.fromJID
    }

    private var linkPreview: LinkPreview? {
        theme.current.showLinkPreviews ? windowState.linkPreview(for: message) : nil
    }

    /// In a one-to-one chat with someone in your contact list, their photos load on sight. Anyone else's wait for a
    /// click, so a stranger's link is not fetched merely by being shown.
    private var loadsIncomingImagesOnSight: Bool {
        !windowState.isGroupchat && windowState.contact != nil
    }

    private var hasCodeBlock: Bool {
        message.styledBodySegments?.contains(where: \.isCodeBlock) == true
    }

    private var showAvatar: Bool {
        theme.current.showAvatars && !message.isOutgoing && theme.current.avatarPosition == .leading
    }

    var body: some View {
        let linkPreview = linkPreview
        HStack(alignment: .bottom) {
            if message.isOutgoing { Spacer(minLength: 60) }

            if showAvatar {
                if position.isLastInGroup {
                    SenderAvatarView(windowState: windowState, nickname: message.fromJID)
                } else {
                    Color.clear
                        .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
                }
            }

            MessageContentView(
                message: message,
                isGroupchatIncoming: isGroupchatIncoming,
                isMetadataVisible: position.isLastInGroup || isHovered,
                actionSenderName: actionSenderName,
                loadsIncomingImagesOnSight: loadsIncomingImagesOnSight,
                header: {
                    if let replied = repliedMessage {
                        ReplyQuoteView(
                            senderName: replied.isOutgoing ? "You" : replied.fromJID,
                            bodyPreview: replied.previewText
                        )
                    }
                },
                footer: {
                    if let linkPreview {
                        LinkPreviewCard(preview: linkPreview)
                    }
                }
            )

            if !message.isOutgoing { Spacer(minLength: 60) }
        }
        // Attachments, link previews and code blocks carry their own controls, which a combined element would hide from assistive tech.
        .accessibilityElement(children: message.attachments.isEmpty && linkPreview == nil && !hasCodeBlock ? .combine : .contain)
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
