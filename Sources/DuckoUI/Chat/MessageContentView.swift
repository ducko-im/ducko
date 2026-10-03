import DuckoCore
import SwiftUI

/// Shared message bubble content used by both MessageBubbleView and TranscriptBubbleView.
/// Renders groupchat sender label, retracted/content bubble, and metadata.
struct MessageContentView<Header: View, Footer: View>: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let isGroupchatIncoming: Bool
    let isMetadataVisible: Bool
    let actionSenderName: String
    /// Whether a received remote image is fetched without the viewer asking for it.
    let loadsIncomingImagesOnSight: Bool
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    private var isActionMessage: Bool {
        message.body.hasPrefix("/me ")
    }

    private var actionText: String {
        String(message.body.dropFirst(4))
    }

    private var showsBody: Bool {
        !message.body.isEmpty && !message.bodyIsAttachmentLink
    }

    private var isImageOnlyMessage: Bool {
        !showsBody && message.attachments.count == 1 && message.attachments[0].isImage
    }

    /// Derived from the text color so code stands apart on either bubble color.
    private var codeTint: Color {
        theme.textColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme).opacity(0.12)
    }

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
            if isGroupchatIncoming {
                Text(message.fromJID)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.forNickname(message.fromJID, colorScheme: colorScheme))
                    .padding(.leading, 4)
            }

            if message.isRetracted {
                noticeBubble("This message was retracted")
                    .accessibilityIdentifier("retracted-message")
            } else if message.isUndecryptable {
                noticeBubble(ChatMessage.undecryptableText)
                    .accessibilityIdentifier("undecryptable-message")
            } else {
                header

                if isImageOnlyMessage {
                    AttachmentView(attachment: message.attachments[0], isOutgoing: message.isOutgoing, loadsIncomingImageOnSight: loadsIncomingImagesOnSight)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(message.attachments) { attachment in
                            AttachmentView(attachment: attachment, isOutgoing: message.isOutgoing, loadsIncomingImageOnSight: loadsIncomingImagesOnSight)
                        }

                        if showsBody {
                            if isActionMessage {
                                Text("* \(actionSenderName) \(actionText)")
                                    .italic()
                            } else if let segments = message.styledBodySegments {
                                styledBody(segments)
                            } else {
                                Text(message.body)
                            }
                        }

                        footer
                    }
                    .padding(.horizontal, theme.current.bubblePadding)
                    .padding(.vertical, theme.current.bubblePadding * 0.67)
                    .background(
                        theme.bubbleColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme),
                        in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
                    )
                    .foregroundStyle(theme.textColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme))
                }
            }

            DirectTransferStatusView(message: message)

            MessageMetadataView(
                message: message,
                isVisible: isMetadataVisible
            )
        }
    }

    private func styledBody(_ segments: [MessageBodySegment]) -> some View {
        ForEach(segments.enumerated(), id: \.offset) { _, segment in
            switch segment {
            case let .text(text):
                Text(tintingCode(in: text))
            case let .codeBlock(code):
                CodeBlockView(code: code, tint: codeTint)
            }
        }
    }

    /// A bubble that stands in for a message with no text of its own to show.
    private func noticeBubble(_ text: String) -> some View {
        Text(text)
            .italic()
            .foregroundStyle(.secondary)
            .padding(.horizontal, theme.current.bubblePadding)
            .padding(.vertical, theme.current.bubblePadding * 0.67)
            .background(
                theme.bubbleColor(isOutgoing: message.isOutgoing, colorScheme: colorScheme),
                in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
            )
    }

    private func tintingCode(in text: AttributedString) -> AttributedString {
        var text = text
        for range in MessageBodySegment.codeRanges(in: text) {
            text[range].backgroundColor = codeTint
        }
        return text
    }
}

extension MessageContentView where Header == EmptyView, Footer == EmptyView {
    init(
        message: ChatMessage,
        isGroupchatIncoming: Bool,
        isMetadataVisible: Bool,
        actionSenderName: String,
        loadsIncomingImagesOnSight: Bool
    ) {
        self.init(
            message: message,
            isGroupchatIncoming: isGroupchatIncoming,
            isMetadataVisible: isMetadataVisible,
            actionSenderName: actionSenderName,
            loadsIncomingImagesOnSight: loadsIncomingImagesOnSight,
            header: { EmptyView() },
            footer: { EmptyView() }
        )
    }
}
