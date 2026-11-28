import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCore

private let testContext = FilterContext(
    accountJID: BareJID.parse("user@example.com")!
)

enum LinkDetectionFilterTests {
    struct DetectsHTTPURL {
        @Test
        func `Detects a single HTTP URL in body`() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Check out https://example.com/page")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.count == 1)
            #expect(result.detectedURLs[0].absoluteString == "https://example.com/page")
        }
    }

    struct DetectsMultipleURLs {
        @Test
        func `Detects multiple URLs in body`() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Visit https://example.com and http://test.org/path")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.count == 2)
        }
    }

    struct SkipsEncryptedFileLinks {
        @Test
        func `An aesgcm link is not detected, while a web link beside it is`() async {
            let filter = LinkDetectionFilter()
            let key = String(repeating: "ab", count: 44)
            let content = MessageContent(body: "aesgcm://upload.example.com/a.png#\(key) and https://example.com/page")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.map(\.absoluteString) == ["https://example.com/page"])
        }
    }

    struct NoURLs {
        @Test
        func `Returns empty detectedURLs for plain text`() async {
            let filter = LinkDetectionFilter()
            let content = MessageContent(body: "Hello, how are you?")
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.detectedURLs.isEmpty)
        }
    }

    struct PreservesBody {
        @Test
        func `Body text is unchanged after filtering`() async {
            let filter = LinkDetectionFilter()
            let body = "Check https://example.com please"
            let content = MessageContent(body: body)
            let result = await filter.filter(content, direction: .incoming, context: testContext)
            #expect(result.body == body)
        }
    }
}
