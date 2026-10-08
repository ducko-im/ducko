import DuckoCore
import SwiftUI

/// Shared message bubble content used by both MessageBubbleView and TranscriptBubbleView.
/// Renders groupchat sender label, retracted/content bubble, and metadata.
struct MessageContentView<Header: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: ChatMessage
    let isGroupchatIncoming: Bool
    let isMetadataVisible: Bool
    let actionSenderName: String
    /// Whether a received remote image is fetched without the viewer asking for it.
    let loadsIncomingImagesOnSight: Bool
    let transferStatus: DirectTransferStatus?
    /// A search's text, whose occurrences in the message's text are highlighted.
    var highlight: String?
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
        Palette.bubbleText(isOutgoing: message.isOutgoing).opacity(0.12)
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
                            Group {
                                if isActionMessage {
                                    actionLine
                                        .italic()
                                } else if let segments = message.styledBodySegments {
                                    styledBody(segments)
                                } else {
                                    Text(message.body, highlighting: highlight)
                                }
                            }
                            .textSelection(.enabled)
                        }

                        footer
                    }
                    .modifier(BubbleChrome(isOutgoing: message.isOutgoing))
                    .foregroundStyle(Palette.bubbleText(isOutgoing: message.isOutgoing))
                }
            }

            DirectTransferStatusView(status: transferStatus)

            MessageMetadataView(
                message: message,
                isVisible: isMetadataVisible
            )
        }
        // The row around this stack hands it the row's height, which the stack would share out among its parts by how
        // much each can give: a reply quote's bar takes what a long text is then cut short by.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var actionLine: Text {
        Text("* \(actionSenderName) \(actionText)", highlighting: highlight)
    }

    private func styledBody(_ segments: [MessageBodySegment]) -> some View {
        ForEach(segments.enumerated(), id: \.offset) { _, segment in
            switch segment {
            case let .text(text):
                Text(highlighted(tintingCode(in: text)))
            case let .codeBlock(code):
                CodeBlockView(code: code, tint: codeTint, highlight: highlight)
            }
        }
    }

    /// A bubble that stands in for a message with no text of its own to show.
    private func noticeBubble(_ text: String) -> some View {
        Text(text)
            .italic()
            .foregroundStyle(.secondary)
            .modifier(BubbleChrome(isOutgoing: message.isOutgoing))
    }

    private func highlighted(_ text: AttributedString) -> AttributedString {
        highlight.map { highlightingMatches(of: $0, in: text) } ?? text
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
        loadsIncomingImagesOnSight: Bool,
        transferStatus: DirectTransferStatus?,
        highlight: String? = nil
    ) {
        self.init(
            message: message,
            isGroupchatIncoming: isGroupchatIncoming,
            isMetadataVisible: isMetadataVisible,
            actionSenderName: actionSenderName,
            loadsIncomingImagesOnSight: loadsIncomingImagesOnSight,
            transferStatus: transferStatus,
            highlight: highlight,
            header: { EmptyView() },
            footer: { EmptyView() }
        )
    }
}

/// The padding and fill that make a bubble.
private struct BubbleChrome: ViewModifier {
    private static let padding: CGFloat = 12
    let isOutgoing: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Self.padding)
            .padding(.vertical, Self.padding * 0.67)
            .background(Palette.bubble(isOutgoing: isOutgoing), in: .rect(cornerRadius: 12))
    }
}
