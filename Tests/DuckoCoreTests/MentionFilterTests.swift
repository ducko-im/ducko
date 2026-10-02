import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let filterContext = FilterContext(
    accountJID: BareJID(localPart: "user", domainPart: "example.com")!
)

enum MentionFilterTests {
    struct IncomingMention {
        @Test
        func `Detects @mention and wraps in bold in htmlBody`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.body == "Hey @user check this")
            #expect(result.htmlBody == "Hey <b>@user</b> check this")
        }

        @Test
        func `No mention — no htmlBody added`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Just a normal message")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == nil)
        }

        @Test
        func `Escapes raw body HTML when no upstream htmlBody exists`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "@user <img src=http://evil/x>")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            // The raw `<img>` must be escaped so it can't inject markup into the persisted htmlBody.
            #expect(result.htmlBody == "<b>@user</b> &lt;img src=http://evil/x&gt;")
        }

        @Test
        func `Keeps the raw body's line breaks when no upstream htmlBody exists`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "first line\n@user second line")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == "first line<br><b>@user</b> second line")
        }

        @Test
        func `Preserves an upstream htmlBody instead of re-escaping the raw body`() async {
            let filter = MentionFilter()
            // Styling already produced escaped htmlBody; the mention highlight augments it in place.
            let content = MessageContent(body: "@user hi", htmlBody: "@user <strong>hi</strong>")
            let result = await filter.filter(content, direction: .incoming, context: filterContext)
            #expect(result.htmlBody == "<b>@user</b> <strong>hi</strong>")
        }
    }

    struct OutgoingPassthrough {
        @Test
        func `Does not process outgoing messages`() async {
            let filter = MentionFilter()
            let content = MessageContent(body: "Hey @user check this")
            let result = await filter.filter(content, direction: .outgoing, context: filterContext)
            #expect(result.htmlBody == nil)
        }
    }
}
