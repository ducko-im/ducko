/// An XEP-0461 reply's reference to the message it answers. The reply's body starts with a quote of that message
/// (§5) for clients that show no reply, marked as its fallback (XEP-0428) so the others can hide it.
public struct MessageReply: Sendable {
    /// The id of the message replied to: the stanza-id the room assigned to it in a room, its own id elsewhere.
    public let id: String
    /// The author of the message replied to.
    public let author: JID
    private let quote: String

    public init(to id: String, by author: JID, quoting quotedText: String) {
        self.init(
            to: id, by: author,
            quote: quotedText.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)\n" }
                .joined()
        )
    }

    /// A reference whose body starts with `quote` as it stands, such as the quote a corrected reply carried.
    public init(to id: String, by author: JID, quote: String) {
        self.id = id
        self.author = author
        self.quote = quote
    }

    /// The reply's body: the quote, then `text`.
    public func body(replying text: String) -> String {
        quote + text
    }

    /// Where the quote stands in the body, in Unicode scalars.
    public var fallbackRange: Range<Int> {
        0 ..< quote.unicodeScalars.count
    }

    /// The `<reply>` reference and, when the body quotes the message, the `<fallback>` marking the quote.
    public var elements: [XMLElement] {
        let reference = XMLElement(name: "reply", namespace: XMPPNamespaces.messageReply, attributes: ["to": author.description, "id": id])
        guard !quote.isEmpty else { return [reference] }
        return [reference, FallbackIndication(for: XMPPNamespaces.messageReply, bodyRange: fallbackRange).element]
    }
}

public extension XMPPMessage {
    /// The part of `body` that quotes the message this one replies to.
    func replyFallbackRange(in body: String) -> Range<Int>? {
        fallbackIndication(for: XMPPNamespaces.messageReply)?.bodyRange(in: body)
    }
}
