import Foundation
import Testing
@testable import DuckoUI

struct MessageBodySegmentTests {
    private func segments(ofHTML html: String) throws -> [String] {
        let body = try #require(HTMLAttributedStringParser.parse(html))
        return MessageBodySegment.segments(of: body).map { segment in
            switch segment {
            case let .text(text): "text: \(String(text.characters))"
            case let .codeBlock(code): "code: \(code)"
            }
        }
    }

    @Test
    func `A code block is split out from the text around it`() throws {
        let segments = try segments(ofHTML: "try this:<pre><code>let x = 1\n  print(x)</code></pre>and then run it")
        #expect(segments == ["text: try this:", "code: let x = 1\n  print(x)", "text: and then run it"])
    }

    @Test
    func `A message that is only a code block has no text around it`() throws {
        let segments = try segments(ofHTML: "<pre><code>only</code></pre>")
        #expect(segments == ["code: only"])
    }

    @Test
    func `Code within a line of text stays in the text`() throws {
        let segments = try segments(ofHTML: "run <code>swift build</code> first")
        #expect(segments == ["text: run swift build first"])
    }

    @Test
    func `Code on a line of its own is a block`() throws {
        let segments = try segments(ofHTML: "see:<br><code>swift build</code><br>ok")
        #expect(segments == ["text: see:", "code: swift build", "text: ok"])
    }

    @Test
    func `Inline code on the lines around a block stays with its own line`() throws {
        let segments = try segments(ofHTML: "run <code>x</code><pre><code>code\nmore</code></pre><code>y</code> ends it")
        #expect(segments == ["text: run x", "code: code\nmore", "text: y ends it"])
    }

    @Test
    func `Text set in a monospaced font is not code`() throws {
        let segments = try segments(ofHTML: #"<span style="font-family: Menlo; font-size: 12pt;">one<br>two</span>"#)
        #expect(segments == ["text: one\ntwo"])
    }

    @Test
    func `Text without code is one segment`() throws {
        let segments = try segments(ofHTML: "one<br>two <strong>three</strong>")
        #expect(segments == ["text: one\ntwo three"])
    }
}
