/// Detects @mentions of the account JID's local part in incoming messages
/// and wraps them in bold tags in htmlBody for visual highlighting.
struct MentionFilter: MessageFilter {
    let priority = 50

    init() {}

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard direction == .incoming else { return content }
        guard let localPart = context.accountJID.localPart else { return content }

        let mention = "@\(localPart)"
        guard content.body.contains(mention) else { return content }

        // When no upstream filter produced htmlBody, the raw body becomes the HTML base — escape it first so an
        // incoming/archived body like `@user <img src=…>` can't inject unescaped markup into the persisted
        // htmlBody (later rendered via NSAttributedString(html:)). An existing htmlBody is already escaped.
        let htmlBody = content.htmlBody ?? MessageStylingHTMLRenderer.renderProse(content.body)
        let highlightedHTML = htmlBody.replacingOccurrences(of: mention, with: "<b>\(mention)</b>")

        return MessageContent(body: content.body, htmlBody: highlightedHTML, detectedURLs: content.detectedURLs)
    }
}
