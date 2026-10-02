import Testing
@testable import DuckoUI

enum HTMLRenderingTests {
    struct BasicParsing {
        @Test
        func `Bold tags produce correct plain text`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>hello</b> world"))
            let plainText = String(attributed.characters)
            #expect(plainText == "hello world")
        }

        @Test
        func `Mixed inline tags produce correct plain text`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>bold</b> and <i>italic</i>"))
            let plainText = String(attributed.characters)
            #expect(plainText == "bold and italic")
        }

        @Test
        func `Invalid HTML still parses`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>unclosed bold"))
            let plainText = String(attributed.characters)
            #expect(plainText == "unclosed bold")
        }

        @Test
        func `Plain text without HTML passes through`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("just plain text"))
            let plainText = String(attributed.characters)
            #expect(plainText == "just plain text")
        }

        @Test
        func `Parsed result strips font and foreground color`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>styled</b>"))
            #expect(attributed.runs.first?.font == nil)
            #expect(attributed.runs.first?.foregroundColor == nil)
        }
    }

    struct FontStripping {
        @Test
        func `Strips AppKit font from per-run attributes`() throws {
            let html = #"<span style="font-family: Helvetica; font-size: 12pt;">hello</span>"#
            let attributed = try #require(HTMLAttributedStringParser.parse(html))
            for run in attributed.runs {
                #expect(run.appKit.font == nil)
            }
        }

        @Test
        func `Strips AppKit foreground color from per-run attributes`() throws {
            let html = #"<span style="color: #ff0000;">red text</span>"#
            let attributed = try #require(HTMLAttributedStringParser.parse(html))
            for run in attributed.runs {
                #expect(run.appKit.foregroundColor == nil)
            }
        }

        @Test
        func `Strips AppKit background color from per-run attributes`() throws {
            let html = #"<span style="background-color: #ffffff;">boxed text</span>"#
            let attributed = try #require(HTMLAttributedStringParser.parse(html))
            for run in attributed.runs {
                #expect(run.appKit.backgroundColor == nil)
            }
        }

        @Test
        func `Preserves bold as InlinePresentationIntent`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<b>bold</b>"))
            let run = try #require(attributed.runs.first)
            let intents = try #require(run.inlinePresentationIntent)
            #expect(intents.contains(.stronglyEmphasized))
        }

        @Test
        func `Preserves italic as InlinePresentationIntent`() throws {
            let attributed = try #require(HTMLAttributedStringParser.parse("<i>italic</i>"))
            let run = try #require(attributed.runs.first)
            let intents = try #require(run.inlinePresentationIntent)
            #expect(intents.contains(.emphasized))
        }

        @Test
        func `Strips Adium-style inline CSS font while preserving text`() throws {
            let html = #"<span style="font-family: Helvetica; font-size: 12pt; color: #000000;">message</span>"#
            let attributed = try #require(HTMLAttributedStringParser.parse(html))
            #expect(String(attributed.characters) == "message")
            for run in attributed.runs {
                #expect(run.appKit.font == nil)
                #expect(run.appKit.foregroundColor == nil)
            }
        }
    }
}
