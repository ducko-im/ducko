import DuckoXMPP

/// Replies (XEP-0461). A reply's stored body is the body as sent or received, quote included, and its display-only
/// `htmlBody` covers only the reply's own text. Whether the quote shows is decided where the reply is drawn.
public extension ChatMessage {
    /// The id a reply names this message by: the stanza-id the room assigned to a room message (§4.1), the message's
    /// own id elsewhere.
    var replyReference: String? {
        type == "groupchat" ? serverID : stanzaID
    }

    /// Whether this message is the one `reply` answers. Outside rooms an id is unique only per sender, so the message
    /// also has to be by the author the reply names, when it names one.
    func isQuoted(by reply: ChatMessage) -> Bool {
        guard let reference = replyReference, reference == reply.replyToID else { return false }
        guard type != "groupchat", let author = reply.replyToJID.flatMap(JID.parse) else { return true }
        // An incoming message is stored under its sender: the bare JID in a 1:1 chat, the nickname in a room's private
        // chat. An outgoing one stores the other party, so any other author named is the user.
        let isByAuthor = switch author {
        case let .bare(jid): fromJID == jid.description
        case let .full(jid): fromJID == jid.bareJID.description || fromJID == jid.resourcePart
        }
        return isOutgoing != isByAuthor
    }

    /// The reply as drawn below its quote of the message it answers: without the quote its body carries.
    func hidingReplyFallback() -> ChatMessage {
        guard let range = validReplyFallbackRange else { return self }
        var message = self
        message.body = body.removingUnicodeScalars(at: range)
        message.replyFallbackRange = nil
        return message
    }

    /// The reply as drawn without a quote of the message it answers: with the quote its body carries as text.
    func showingReplyFallback() -> ChatMessage {
        guard let range = validReplyFallbackRange, let htmlBody else { return self }
        var message = self
        message.htmlBody = range.lowerBound == 0
            ? MessageStylingHTMLRenderer.renderProse(body.unicodeScalars(at: range)) + htmlBody
            : nil
        return message
    }

    private var validReplyFallbackRange: Range<Int>? {
        replyFallbackRange.flatMap { $0.upperBound <= body.unicodeScalars.count ? $0 : nil }
    }
}

extension ChatMessage {
    /// The reply this message makes, with the quote its body carries, as a correction re-sends it (XEP-0308 §4).
    var messageReply: MessageReply? {
        guard let replyToID, let author = replyToJID.flatMap(JID.parse) else { return nil }
        return MessageReply(to: replyToID, by: author, quote: validReplyFallbackRange.map { body.unicodeScalars(at: $0) } ?? "")
    }
}

extension MessageReply {
    /// The same reference without a quote: the body is the reply's own text alone, and no fallback is marked.
    var withoutQuote: MessageReply {
        MessageReply(to: id, by: author, quote: "")
    }
}
