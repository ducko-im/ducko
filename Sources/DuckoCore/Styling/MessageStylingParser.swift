// XEP-0393 Message Styling AST types and parser.
//
// Two-stage parsing: block-level first (code blocks, block quotes, plain),
// then inline left-to-right lazy matching within plain blocks.

// MARK: - AST

public enum StyledSpan: Sendable, Equatable {
    case plain(String)
    case bold([StyledSpan])
    case italic([StyledSpan])
    case strikethrough([StyledSpan])
    case code(String)
}

public enum StyledBlock: Sendable, Equatable {
    case plain([StyledSpan])
    case codeBlock(String)
    case blockQuote([StyledBlock])
}

// MARK: - Parser

public enum MessageStylingParser {
    public static func parse(_ text: String) -> [StyledBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parseBlocks(lines: lines)
    }

    // MARK: - Block-Level Parsing

    private static func parseBlocks(lines: [String]) -> [StyledBlock] {
        var blocks: [StyledBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            // Code block: line is exactly "```" (with optional leading/trailing whitespace)
            if line.trimmingCharacters(in: .whitespaces) == "```" {
                let (codeBlock, nextIndex) = parseCodeBlock(lines: lines, startIndex: index)
                blocks.append(codeBlock)
                index = nextIndex
                continue
            }

            // Block quote: line starts with "> "
            if line.hasPrefix("> ") {
                let (quoteBlock, nextIndex) = parseBlockQuote(lines: lines, startIndex: index)
                blocks.append(quoteBlock)
                index = nextIndex
                continue
            }

            // Plain block: collect consecutive non-special lines
            let (plainBlock, nextIndex) = parsePlainBlock(lines: lines, startIndex: index)
            blocks.append(plainBlock)
            index = nextIndex
        }

        return blocks
    }

    private static func parseCodeBlock(lines: [String], startIndex: Int) -> (StyledBlock, Int) {
        var codeLines: [String] = []
        var index = startIndex + 1

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "```" {
                return (.codeBlock(codeLines.joined(separator: "\n")), index + 1)
            }
            codeLines.append(line)
            index += 1
        }

        // Unterminated code block — treat opening ``` as plain text
        let openingLine = lines[startIndex]
        return (.plain(parseInline(openingLine)), startIndex + 1)
    }

    private static func parseBlockQuote(lines: [String], startIndex: Int) -> (StyledBlock, Int) {
        var quoteLines: [String] = []
        var index = startIndex

        while index < lines.count, lines[index].hasPrefix("> ") {
            quoteLines.append(String(lines[index].dropFirst(2)))
            index += 1
        }

        let innerBlocks = parseBlocks(lines: quoteLines)
        return (.blockQuote(innerBlocks), index)
    }

    private static func parsePlainBlock(lines: [String], startIndex: Int) -> (StyledBlock, Int) {
        var plainLines: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces) == "```" || line.hasPrefix("> ") {
                break
            }
            plainLines.append(line)
            index += 1
        }

        let text = plainLines.joined(separator: "\n")
        return (.plain(parseInline(text)), index)
    }

    // MARK: - Inline Parsing

    static func parseInline(_ text: String) -> [StyledSpan] {
        var spans: [StyledSpan] = []
        var remaining = text[text.startIndex...]

        while !remaining.isEmpty {
            // Try backtick span first (no nesting)
            if remaining.first == "`" {
                if let (codeSpan, afterIndex) = parseCodeSpan(remaining) {
                    spans.append(codeSpan)
                    remaining = text[afterIndex...]
                    continue
                }
            }

            // Try styled spans: * _ ~
            if let marker = styledMarker(remaining.first), isBoundaryStart(remaining, in: text) {
                if let (styledSpan, afterIndex) = parseStyledSpan(remaining, marker: marker, in: text) {
                    spans.append(styledSpan)
                    remaining = text[afterIndex...]
                    continue
                }
            }

            remaining = text[text.index(after: remaining.startIndex)...]
            if remaining.isEmpty {
                // We've consumed everything character-by-character — flush
            }
        }

        // Any remaining plain text
        if spans.isEmpty, !text.isEmpty {
            spans.append(.plain(text))
        }

        return coalescePlain(spans, originalText: text)
    }

    private static func parseCodeSpan(_ text: Substring) -> (StyledSpan, String.Index)? {
        guard text.first == "`" else { return nil }
        let afterOpen = text.index(after: text.startIndex)
        guard afterOpen < text.endIndex else { return nil }

        if let closeIndex = text[afterOpen...].firstIndex(of: "`") {
            let content = String(text[afterOpen ..< closeIndex])
            guard !content.isEmpty else { return nil }
            return (.code(content), text.index(after: closeIndex))
        }
        return nil
    }

    private enum InlineMarker: Character {
        case bold = "*"
        case italic = "_"
        case strikethrough = "~"
    }

    private static func styledMarker(_ char: Character?) -> InlineMarker? {
        guard let char else { return nil }
        return InlineMarker(rawValue: char)
    }

    private static func isBoundaryStart(_ text: Substring, in fullText: String) -> Bool {
        let idx = text.startIndex
        if idx == fullText.startIndex { return true }
        let prev = fullText[fullText.index(before: idx)]
        return prev == " " || prev == "\n" || prev == "\t"
    }

    private static func isWhitespace(_ char: Character) -> Bool {
        char == " " || char == "\n" || char == "\t"
    }

    private static func isValidCloseBoundary(_ text: Substring, afterClose: String.Index) -> Bool {
        guard afterClose < text.endIndex else { return true }
        let nextChar = text[afterClose]
        return !nextChar.isLetter && !nextChar.isNumber
    }

    private static func parseStyledSpan(
        _ text: Substring, marker: InlineMarker, in _: String
    ) -> (StyledSpan, String.Index)? {
        let markerChar = marker.rawValue
        let afterOpen = text.index(after: text.startIndex)
        guard afterOpen < text.endIndex, !isWhitespace(text[afterOpen]) else { return nil }

        var searchFrom = afterOpen
        while searchFrom < text.endIndex {
            guard let closeIndex = text[searchFrom...].firstIndex(of: markerChar) else { return nil }
            let afterClose = text.index(after: closeIndex)

            guard closeIndex > afterOpen,
                  !isWhitespace(text[text.index(before: closeIndex)]),
                  isValidCloseBoundary(text, afterClose: afterClose) else {
                searchFrom = afterClose
                continue
            }

            let innerSpans = parseInline(String(text[afterOpen ..< closeIndex]))
            let span: StyledSpan = switch marker {
            case .bold: .bold(innerSpans)
            case .italic: .italic(innerSpans)
            case .strikethrough: .strikethrough(innerSpans)
            }
            return (span, afterClose)
        }
        return nil
    }

    /// Reconstructs plain text spans that were skipped during character-by-character scanning.
    private static func coalescePlain(_ spans: [StyledSpan], originalText: String) -> [StyledSpan] {
        guard !spans.isEmpty else { return [.plain(originalText)] }

        // Rebuild: walk the original text and fill gaps between styled spans
        var result: [StyledSpan] = []
        var offset = originalText.startIndex

        for span in spans {
            let rendered = spanToString(span)
            if let range = originalText.range(of: rendered, range: offset ..< originalText.endIndex) {
                if offset < range.lowerBound {
                    let plainText = String(originalText[offset ..< range.lowerBound])
                    result.append(.plain(plainText))
                }
                result.append(span)
                offset = range.upperBound
            }
        }

        if offset < originalText.endIndex {
            result.append(.plain(String(originalText[offset...])))
        }

        return result
    }

    private static func spanToString(_ span: StyledSpan) -> String {
        switch span {
        case let .plain(text): text
        case let .bold(inner): "*\(inner.map { spanToString($0) }.joined())*"
        case let .italic(inner): "_\(inner.map { spanToString($0) }.joined())_"
        case let .strikethrough(inner): "~\(inner.map { spanToString($0) }.joined())~"
        case let .code(text): "`\(text)`"
        }
    }
}
