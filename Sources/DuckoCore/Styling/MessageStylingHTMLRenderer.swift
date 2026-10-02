/// Renders XEP-0393 styled blocks as HTML for GUI display.
enum MessageStylingHTMLRenderer {
    static func render(_ blocks: [StyledBlock]) -> String {
        blocks.map { renderBlock($0) }.joined()
    }

    private static func renderBlock(_ block: StyledBlock) -> String {
        switch block {
        case let .plain(spans):
            return spans.map { renderSpan($0) }.joined()
        case let .codeBlock(code):
            return "<pre><code>\(escapeHTML(code))</code></pre>"
        case let .blockQuote(inner):
            return "<blockquote>\(inner.map { renderBlock($0) }.joined())</blockquote>"
        }
    }

    private static func renderSpan(_ span: StyledSpan) -> String {
        switch span {
        case let .plain(text):
            return renderProse(text)
        case let .bold(inner):
            return "<strong>\(inner.map { renderSpan($0) }.joined())</strong>"
        case let .italic(inner):
            return "<em>\(inner.map { renderSpan($0) }.joined())</em>"
        case let .strikethrough(inner):
            return "<del>\(inner.map { renderSpan($0) }.joined())</del>"
        case let .code(text):
            return "<code>\(escapeHTML(text))</code>"
        }
    }

    /// Escapes text shown as prose. HTML collapses a bare newline into a space, so each one becomes a `<br>`.
    static func renderProse(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
