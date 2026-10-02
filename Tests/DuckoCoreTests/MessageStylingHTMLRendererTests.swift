import Testing
@testable import DuckoCore

enum MessageStylingHTMLRendererTests {
    struct RenderTests {
        @Test
        func `bold renders as strong`() {
            let blocks: [StyledBlock] = [.plain([.bold([.plain("hello")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<strong>hello</strong>")
        }

        @Test
        func `italic renders as em`() {
            let blocks: [StyledBlock] = [.plain([.italic([.plain("hello")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<em>hello</em>")
        }

        @Test
        func `strikethrough renders as del`() {
            let blocks: [StyledBlock] = [.plain([.strikethrough([.plain("hello")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<del>hello</del>")
        }

        @Test
        func `code renders as code`() {
            let blocks: [StyledBlock] = [.plain([.code("hello")])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<code>hello</code>")
        }

        @Test
        func `code block renders as pre code`() {
            let blocks: [StyledBlock] = [.codeBlock("one\n  two")]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<pre><code>one\n  two</code></pre>")
        }

        @Test
        func `block quote renders as blockquote`() {
            let blocks: [StyledBlock] = [.blockQuote([.plain([.plain("hello")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<blockquote>hello</blockquote>")
        }

        @Test
        func `HTML entities are escaped`() {
            let blocks: [StyledBlock] = [.plain([.plain("<script>alert(1)</script>")])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "&lt;script&gt;alert(1)&lt;/script&gt;")
        }

        @Test
        func `line breaks in prose render as br`() {
            let blocks: [StyledBlock] = [.plain([.plain("one\ntwo "), .bold([.plain("three")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "one<br>two <strong>three</strong>")
        }

        @Test
        func `nested spans render correctly`() {
            let blocks: [StyledBlock] = [.plain([.bold([.italic([.plain("hello")])])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "<strong><em>hello</em></strong>")
        }

        @Test
        func `mixed plain and styled`() {
            let blocks: [StyledBlock] = [.plain([.plain("hello "), .bold([.plain("world")])])]
            let html = MessageStylingHTMLRenderer.render(blocks)
            #expect(html == "hello <strong>world</strong>")
        }
    }
}
