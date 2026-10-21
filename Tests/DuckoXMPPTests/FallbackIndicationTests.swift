import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// A quote with an emoji of two scalars and an accent written as a combining mark, so counting characters or UTF-16
/// units gives a different length than counting Unicode scalars.
private let quotedText = "👍🏽 cafe\u{301}"
private let quoteScalarCount = 11

private func message(fallback: String) throws -> XMPPMessage {
    try XMPPMessage(element: stanza("""
    <message from='contact@example.com/phone' type='chat' id='m1'>\
    <body>&gt; \(quotedText)
    reply</body>\
    <reply xmlns='urn:xmpp:reply:0' id='quoted-1' to='contact@example.com/phone'/>\
    \(fallback)\
    </message>
    """))
}

// MARK: - Tests

enum FallbackIndicationTests {
    struct Sending {
        @Test
        func `A reply's quote is counted in Unicode scalars`() throws {
            let author = try #require(JID.parse("contact@example.com"))
            let reply = MessageReply(to: "quoted-1", by: author, quoting: quotedText)

            #expect(reply.fallbackRange == 0 ..< quoteScalarCount)
            #expect(reply.body(replying: "reply").removingUnicodeScalars(at: reply.fallbackRange) == "reply")
        }
    }

    struct Receiving {
        @Test
        func `A body range is read in Unicode scalars`() throws {
            let received = try message(fallback: """
            <fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='\(quoteScalarCount)'/></fallback>
            """)
            let body = try #require(received.body)

            let range = try #require(received.fallbackIndication(for: XMPPNamespaces.messageReply)?.bodyRange(in: body))

            #expect(body.removingUnicodeScalars(at: range) == "reply")
            #expect(body.unicodeScalars(at: range) == "> \(quotedText)\n")
        }

        @Test(arguments: [
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'/>", 0 ..< quoteScalarCount + 5),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='99'/></fallback>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='5' end='2'/></fallback>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:message-retract:1'/>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><subject/></fallback>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><subject start='0' end='3'/></fallback>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='2'/><body start='2' end='11'/></fallback>", 0 ..< 11),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='4' end='11'/><body start='0' end='5'/></fallback>", 0 ..< 11),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='2'/><body start='5' end='11'/></fallback>", nil),
            ("<fallback xmlns='urn:xmpp:fallback:0' for='urn:xmpp:reply:0'><body start='0' end='2'/><body/></fallback>", 0 ..< quoteScalarCount + 5)
        ] as [(String, Range<Int>?)])
        func `A fallback marks the body parts it names, the whole body without a range, and none for a subject, a gap or a range past the body`(
            fallback: String, expected: Range<Int>?
        ) throws {
            let received = try message(fallback: fallback)
            let body = try #require(received.body)

            #expect(received.fallbackIndication(for: XMPPNamespaces.messageReply)?.bodyRange(in: body) == expected)
        }
    }
}
