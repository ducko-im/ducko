/// XEP-0393 message styling filter. Priority 5 — runs before link detection (10) and mentions (50) so styled HTML is the base later filters augment.
struct StylingFilter: MessageFilter {
    let priority = 5

    init() {}

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard !content.isUnstyled, !content.body.isEmpty else { return content }

        let blocks = MessageStylingParser.parse(content.body)

        guard hasStyledContent(blocks) else { return content }

        let html = MessageStylingHTMLRenderer.render(blocks)
        return MessageContent(
            body: content.body,
            htmlBody: html,
            detectedURLs: content.detectedURLs,
            isUnstyled: content.isUnstyled
        )
    }

    private func hasStyledContent(_ blocks: [StyledBlock]) -> Bool {
        for block in blocks {
            switch block {
            case .codeBlock, .blockQuote:
                return true
            case let .plain(spans):
                for span in spans {
                    switch span {
                    case .plain:
                        continue
                    case .bold, .italic, .strikethrough, .code:
                        return true
                    }
                }
            }
        }
        return false
    }
}
