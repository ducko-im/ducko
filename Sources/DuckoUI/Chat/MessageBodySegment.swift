import DuckoCore
import Foundation

extension ChatMessage {
    /// The styled body in the pieces it is drawn in, or nil for a message without styling.
    var styledBodySegments: [MessageBodySegment]? {
        htmlBody.flatMap(MessageBodySegment.segments(ofHTML:))
    }
}

/// Code blocks are drawn apart from the text around them.
enum MessageBodySegment {
    case text(AttributedString)
    case codeBlock(String)

    private final class Segments {
        let value: [MessageBodySegment]

        init(_ value: [MessageBodySegment]) {
            self.value = value
        }
    }

    private nonisolated(unsafe) static let cache = NSCache<NSString, Segments>()

    var isCodeBlock: Bool {
        switch self {
        case .text: false
        case .codeBlock: true
        }
    }

    static func segments(ofHTML html: String) -> [MessageBodySegment]? {
        let key = html as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        guard let body = HTMLAttributedStringParser.parse(html) else { return nil }
        let segments = segments(of: body)
        cache.setObject(Segments(segments), forKey: key)
        return segments
    }

    /// Splits `body` at its code blocks: code that fills whole lines. Code within a line of text stays in the text.
    static func segments(of body: AttributedString) -> [MessageBodySegment] {
        var segments: [MessageBodySegment] = []
        var textStart = body.startIndex
        for range in codeRanges(in: body) {
            let codeRange = wholeLines(of: range, in: body)
            guard !codeRange.isEmpty else { continue }
            appendText(textStart ..< codeRange.lowerBound, of: body, to: &segments)
            segments.append(.codeBlock(String(body.characters[codeRange])))
            textStart = codeRange.upperBound
        }
        appendText(textStart ..< body.endIndex, of: body, to: &segments)
        return segments
    }

    /// The ranges of code in `body`, with runs that only differ in other attributes joined.
    static func codeRanges(in body: AttributedString) -> [Range<AttributedString.Index>] {
        var ranges: [Range<AttributedString.Index>] = []
        for run in body.runs where run.inlinePresentationIntent?.contains(.code) == true {
            if let last = ranges.last, last.upperBound == run.range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound ..< run.range.upperBound
            } else {
                ranges.append(run.range)
            }
        }
        return ranges
    }

    private static func appendText(_ range: Range<AttributedString.Index>, of body: AttributedString, to segments: inout [MessageBodySegment]) {
        let textRange = trimmingNewlines(range, in: body)
        guard !textRange.isEmpty else { return }
        segments.append(.text(AttributedString(body[textRange])))
    }

    /// The part of a code range that covers whole lines. Code that ends the line before a block, or starts the
    /// line after it, arrives joined to the block and stays with its own line's text.
    private static func wholeLines(of range: Range<AttributedString.Index>, in body: AttributedString) -> Range<AttributedString.Index> {
        let characters = body.characters
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        if lowerBound != characters.startIndex, !characters[characters.index(before: lowerBound)].isNewline {
            lowerBound = characters[range].firstIndex(where: \.isNewline) ?? upperBound
        }
        if upperBound != characters.endIndex, !characters[upperBound].isNewline {
            upperBound = characters[lowerBound ..< upperBound].lastIndex(where: \.isNewline) ?? lowerBound
        }
        return trimmingNewlines(lowerBound ..< upperBound, in: body)
    }

    /// The line breaks at a segment's edges only separate it from its neighbors, which the layout does already.
    private static func trimmingNewlines(_ range: Range<AttributedString.Index>, in body: AttributedString) -> Range<AttributedString.Index> {
        let characters = body.characters
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        while lowerBound < upperBound, characters[lowerBound].isNewline {
            lowerBound = characters.index(after: lowerBound)
        }
        while lowerBound < upperBound, characters[characters.index(before: upperBound)].isNewline {
            upperBound = characters.index(before: upperBound)
        }
        return lowerBound ..< upperBound
    }
}
