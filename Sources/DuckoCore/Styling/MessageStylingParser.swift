// XEP-0393 Message Styling AST types and parser.
//
// Two-stage parsing: block-level first (code blocks, block quotes, plain),
// then inline left-to-right lazy matching within each line of a plain block.

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
    /// Quotes nested deeper than this read as plain text, so a body of many `>` cannot exhaust the stack.
    static let maxQuoteDepth = 32

    public static func parse(_ text: String) -> [StyledBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return parseBlocks(lines: lines, quoteDepth: 0)
    }

    // MARK: - Block-Level Parsing

    private static func parseBlocks(lines: [String], quoteDepth: Int) -> [StyledBlock] {
        var blocks: [StyledBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if opensCodeBlock(line) {
                let (codeBlock, nextIndex) = parseCodeBlock(lines: lines, startIndex: index)
                blocks.append(codeBlock)
                index = nextIndex
                continue
            }

            if opensBlockQuote(line, quoteDepth: quoteDepth) {
                let (quoteBlock, nextIndex) = parseBlockQuote(lines: lines, startIndex: index, quoteDepth: quoteDepth)
                blocks.append(quoteBlock)
                index = nextIndex
                continue
            }

            let (plainBlock, nextIndex) = parsePlainBlock(lines: lines, startIndex: index, quoteDepth: quoteDepth)
            blocks.append(plainBlock)
            index = nextIndex
        }

        return blocks
    }

    private static func opensCodeBlock(_ line: String) -> Bool {
        line.hasPrefix("```")
    }

    private static func opensBlockQuote(_ line: String, quoteDepth: Int) -> Bool {
        quoteDepth < maxQuoteDepth && line.hasPrefix(">")
    }

    /// Runs to a line of exactly three backticks, or to the end of the parent block when there is none.
    private static func parseCodeBlock(lines: [String], startIndex: Int) -> (StyledBlock, Int) {
        let contentStart = startIndex + 1
        let closingIndex = lines[contentStart...].firstIndex(of: "```")
        let contentEnd = closingIndex ?? lines.endIndex
        let code = lines[contentStart ..< contentEnd].joined(separator: "\n")
        return (.codeBlock(code), closingIndex.map { $0 + 1 } ?? lines.endIndex)
    }

    private static func parseBlockQuote(lines: [String], startIndex: Int, quoteDepth: Int) -> (StyledBlock, Int) {
        var quoteLines: [String] = []
        var index = startIndex

        while index < lines.count, opensBlockQuote(lines[index], quoteDepth: quoteDepth) {
            var content = lines[index].dropFirst()
            if content.first?.isWhitespace == true {
                content = content.dropFirst()
            }
            quoteLines.append(String(content))
            index += 1
        }

        let innerBlocks = parseBlocks(lines: quoteLines, quoteDepth: quoteDepth + 1)
        return (.blockQuote(innerBlocks), index)
    }

    private static func parsePlainBlock(lines: [String], startIndex: Int, quoteDepth: Int) -> (StyledBlock, Int) {
        var index = startIndex
        while index < lines.count, !opensCodeBlock(lines[index]), !opensBlockQuote(lines[index], quoteDepth: quoteDepth) {
            index += 1
        }
        let text = lines[startIndex ..< index].joined(separator: "\n")
        return (.plain(parseInline(text)), index)
    }

    // MARK: - Inline Parsing

    private enum SpanDirective: Character {
        case bold = "*"
        case italic = "_"
        case strikethrough = "~"
        case code = "`"
    }

    /// Parses the spans of a plain block, left to right and lazily. A span never crosses a line break.
    private static func parseInline(_ text: String) -> [StyledSpan] {
        let spans = parseSpans(text[...])
        return spans.isEmpty ? [.plain("")] : spans
    }

    private static func parseSpans(_ text: Substring) -> [StyledSpan] {
        var spans: [StyledSpan] = []
        var plainStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            if let directive = SpanDirective(rawValue: text[index]),
               index == text.startIndex || text[text.index(before: index)].isWhitespace,
               let (span, end) = matchSpan(directive, openingAt: index, in: text) {
                if plainStart < index {
                    spans.append(.plain(String(text[plainStart ..< index])))
                }
                spans.append(span)
                index = end
                plainStart = end
            } else {
                index = text.index(after: index)
            }
        }

        if plainStart < text.endIndex {
            spans.append(.plain(String(text[plainStart...])))
        }
        return spans
    }

    /// Matches the span an opening directive starts: it closes at the first same directive on its line that does not
    /// follow whitespace. An opening directive followed by whitespace, or directly by its closing one, styles nothing.
    private static func matchSpan(
        _ directive: SpanDirective, openingAt open: Substring.Index, in text: Substring
    ) -> (StyledSpan, Substring.Index)? {
        let contentStart = text.index(after: open)
        guard contentStart < text.endIndex else { return nil }
        let first = text[contentStart]
        guard !first.isWhitespace, first != directive.rawValue else { return nil }

        let lineEnd = text[contentStart...].firstIndex(of: "\n") ?? text.endIndex
        var searchStart = text.index(after: contentStart)
        while let close = text[searchStart ..< lineEnd].firstIndex(of: directive.rawValue) {
            if !text[text.index(before: close)].isWhitespace {
                let content = text[contentStart ..< close]
                let span: StyledSpan = switch directive {
                case .bold: .bold(parseSpans(content))
                case .italic: .italic(parseSpans(content))
                case .strikethrough: .strikethrough(parseSpans(content))
                case .code: .code(String(content))
                }
                return (span, text.index(after: close))
            }
            searchStart = text.index(after: close)
        }
        return nil
    }
}
