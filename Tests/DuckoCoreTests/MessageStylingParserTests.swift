import Testing
@testable import DuckoCore

enum MessageStylingParserTests {
    // MARK: - Inline Styling

    struct InlineTests {
        @Test
        func `bold spans`() {
            let result = MessageStylingParser.parse("hello *world*")
            #expect(result == [.plain([.plain("hello "), .bold([.plain("world")])])])
        }

        @Test
        func `italic spans`() {
            let result = MessageStylingParser.parse("hello _world_")
            #expect(result == [.plain([.plain("hello "), .italic([.plain("world")])])])
        }

        @Test
        func `strikethrough spans`() {
            let result = MessageStylingParser.parse("hello ~world~")
            #expect(result == [.plain([.plain("hello "), .strikethrough([.plain("world")])])])
        }

        @Test
        func `code spans`() {
            let result = MessageStylingParser.parse("use `code` here")
            #expect(result == [.plain([.plain("use "), .code("code"), .plain(" here")])])
        }

        @Test
        func `plain text without markers`() {
            let result = MessageStylingParser.parse("just plain text")
            #expect(result == [.plain([.plain("just plain text")])])
        }

        @Test
        func `empty string`() {
            let result = MessageStylingParser.parse("")
            #expect(result == [.plain([.plain("")])])
        }

        @Test
        func `nested bold inside italic`() {
            let result = MessageStylingParser.parse("_hello *world*_")
            #expect(result == [.plain([.italic([.plain("hello "), .bold([.plain("world")])])])])
        }

        @Test
        func `code does not nest`() {
            let result = MessageStylingParser.parse("`*not bold*`")
            #expect(result == [.plain([.code("*not bold*")])])
        }
    }

    // MARK: - Boundary Rules

    struct BoundaryTests {
        @Test
        func `marker not at word boundary is plain`() {
            let result = MessageStylingParser.parse("foo*bar*baz")
            // *bar* fails boundary start because 'o' precedes '*'
            #expect(result == [.plain([.plain("foo*bar*baz")])])
        }

        @Test
        func `marker with inner whitespace at start fails`() {
            let result = MessageStylingParser.parse("* not bold*")
            #expect(result == [.plain([.plain("* not bold*")])])
        }

        @Test
        func `marker with inner whitespace at end fails`() {
            let result = MessageStylingParser.parse("*not bold *")
            #expect(result == [.plain([.plain("*not bold *")])])
        }

        @Test(arguments: [
            ("plain span", [StyledSpan.plain("plain span")]),
            ("*strong span*", [.bold([.plain("strong span")])]),
            ("plain _emphasis_ plain", [.plain("plain "), .italic([.plain("emphasis")]), .plain(" plain")]),
            ("`pre` plain *strong*", [.code("pre"), .plain(" plain "), .bold([.plain("strong")])]),
            ("*strong*plain*", [.bold([.plain("strong")]), .plain("plain*")]),
            ("* plain *strong*", [.plain("* plain "), .bold([.plain("strong")])]),
            ("Everyone ~dis~likes cake.", [.plain("Everyone "), .strikethrough([.plain("dis")]), .plain("likes cake.")])
        ])
        func `The spec's styled examples`(body: String, spans: [StyledSpan]) {
            #expect(MessageStylingParser.parse(body) == [.plain(spans)])
        }

        @Test(arguments: ["not strong*", "*not strong", "*not *strong", "**", "***", "****", "foo`bar`", "a ` b ` c"])
        func `Bodies nothing in is styled`(body: String) {
            #expect(MessageStylingParser.parse(body) == [.plain([.plain(body)])])
        }

        @Test
        func `A directive after a no-break space opens a span`() {
            let result = MessageStylingParser.parse("a\u{00A0}*b*")
            #expect(result == [.plain([.plain("a\u{00A0}"), .bold([.plain("b")])])])
        }

        @Test
        func `A span is placed where it matched, not at an earlier copy of its text`() {
            let result = MessageStylingParser.parse("foo*bar* *bar*")
            #expect(result == [.plain([.plain("foo*bar* "), .bold([.plain("bar")])])])
        }
    }

    // MARK: - Block-Level

    struct BlockTests {
        @Test
        func `code block`() {
            let result = MessageStylingParser.parse("```\nhello world\n```")
            #expect(result == [.codeBlock("hello world")])
        }

        @Test
        func `multiline code block`() {
            let result = MessageStylingParser.parse("```\nline 1\nline 2\n```")
            #expect(result == [.codeBlock("line 1\nline 2")])
        }

        @Test
        func `code block suppresses inline parsing`() {
            let result = MessageStylingParser.parse("```\n*not bold*\n```")
            #expect(result == [.codeBlock("*not bold*")])
        }

        @Test
        func `code block opening line may carry a hint`() {
            let result = MessageStylingParser.parse("```ignored\n(println \"Hello, world!\")\n```")
            #expect(result == [.codeBlock("(println \"Hello, world!\")")])
        }

        @Test
        func `code block closes only at a line of exactly three backticks`() {
            let result = MessageStylingParser.parse("```\ncode\n``` \nmore\n```")
            #expect(result == [.codeBlock("code\n``` \nmore")])
        }

        @Test
        func `unterminated code block runs to the end of its parent block`() {
            let result = MessageStylingParser.parse("```\nhello")
            #expect(result == [.codeBlock("hello")])
        }

        @Test
        func `unterminated code block inside a quote ends with the quote`() {
            let result = MessageStylingParser.parse("> ```\n> (println \"Hello, world!\")\n\nThis line is plaintext!")
            #expect(result == [
                .blockQuote([.codeBlock("(println \"Hello, world!\")")]),
                .plain([.plain("\nThis line is plaintext!")])
            ])
        }

        @Test
        func `block quote`() {
            let result = MessageStylingParser.parse("> quoted text")
            #expect(result == [.blockQuote([.plain([.plain("quoted text")])])])
        }

        @Test
        func `multiline block quote`() {
            let result = MessageStylingParser.parse("> line 1\n> line 2")
            // Inner lines are joined into a single plain block
            #expect(result == [.blockQuote([.plain([.plain("line 1\nline 2")])])])
        }

        @Test
        func `block quote without a space after the marker`() {
            let result = MessageStylingParser.parse(">quoted text")
            #expect(result == [.blockQuote([.plain([.plain("quoted text")])])])
        }

        @Test
        func `block quote trims a leading no-break space`() {
            let result = MessageStylingParser.parse(">\u{00A0}quoted text")
            #expect(result == [.blockQuote([.plain([.plain("quoted text")])])])
        }

        @Test
        func `quotes nested past the depth limit read as plain text`() {
            let depth = MessageStylingParser.maxQuoteDepth
            var block = StyledBlock.plain([.plain(">x")])
            for _ in 0 ..< depth {
                block = .blockQuote([block])
            }
            #expect(MessageStylingParser.parse(String(repeating: ">", count: depth + 1) + "x") == [block])
        }

        @Test
        func `nested block quote`() {
            let result = MessageStylingParser.parse(">> That that is, is.\n> Said the old hermit of Prague.\n\nWho?")
            #expect(result == [
                .blockQuote([
                    .blockQuote([.plain([.plain("That that is, is.")])]),
                    .plain([.plain("Said the old hermit of Prague.")])
                ]),
                .plain([.plain("\nWho?")])
            ])
        }

        @Test
        func `spans do not cross lines of a plain block`() {
            let result = MessageStylingParser.parse("there is no *formatting\nas spans* may not escape blocks")
            #expect(result == [.plain([.plain("there is no *formatting\nas spans* may not escape blocks")])])
        }

        @Test
        func `block quote with styling`() {
            let result = MessageStylingParser.parse("> *bold* text")
            #expect(result == [.blockQuote([.plain([.bold([.plain("bold")]), .plain(" text")])])])
        }

        @Test
        func `mixed blocks`() {
            let result = MessageStylingParser.parse("hello\n> quote\nworld")
            #expect(result.count == 3)
            #expect(result[0] == .plain([.plain("hello")]))
            #expect(result[1] == .blockQuote([.plain([.plain("quote")])]))
            #expect(result[2] == .plain([.plain("world")]))
        }
    }
}
