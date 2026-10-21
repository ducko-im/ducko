import Testing
@testable import DuckoXMPP

private let streamOpenTag =
    "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='example.com' version='1.0'>"

private func parseChunks(_ chunks: [String]) -> [XMLStreamEvent] {
    let parser = XMPPStreamParser()
    var events: [XMLStreamEvent] = []
    for chunk in chunks {
        events.append(contentsOf: parser.parse(Array(chunk.utf8)))
    }
    events.append(contentsOf: parser.close())
    return events
}

// MARK: - Event Extraction Helpers

extension XMLStreamEvent {
    var streamOpenedAttributes: [String: String]? {
        guard case let .streamOpened(attrs) = self else { return nil }
        return attrs
    }

    var stanzaElement: XMLElement? {
        guard case let .stanzaReceived(element) = self else { return nil }
        return element
    }

    var isStreamClosed: Bool {
        guard case .streamClosed = self else { return false }
        return true
    }

    var isError: Bool {
        guard case .error = self else { return false }
        return true
    }
}

enum XMPPStreamParserTests {
    struct StreamLifecycle {
        @Test
        func `Stream open emits streamOpened with attributes`() throws {
            let events = parseChunks([
                "<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' to='example.com' from='example.com' version='1.0'>"
            ])
            try #require(events.count == 1)
            let attrs = try #require(events[0].streamOpenedAttributes)
            #expect(attrs["xmlns"] == "jabber:client")
            #expect(attrs["xmlns:stream"] == "http://etherx.jabber.org/streams")
            #expect(attrs["to"] == "example.com")
            #expect(attrs["from"] == "example.com")
            #expect(attrs["version"] == "1.0")
        }

        @Test
        func `Stream close emits streamClosed`() throws {
            let events = parseChunks([
                streamOpenTag,
                "</stream:stream>"
            ])
            try #require(events.count == 2)
            #expect(events[0].streamOpenedAttributes != nil)
            #expect(events[1].isStreamClosed)
        }

        @Test
        func `Full lifecycle: open, stanza, close`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message><body>Hi</body></message>",
                "</stream:stream>"
            ])
            try #require(events.count == 3)
            #expect(events[0].streamOpenedAttributes != nil)
            #expect(events[1].stanzaElement != nil)
            #expect(events[2].isStreamClosed)
        }
    }

    struct StanzaParsing {
        @Test
        func `Simple message stanza`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message type='chat' to='user@example.com'><body>Hello</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "message")
            #expect(element.attribute("type") == "chat")
            #expect(element.attribute("to") == "user@example.com")
            #expect(element.child(named: "body")?.textContent == "Hello")
        }

        @Test
        func `Stanza with nested elements`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<iq type='result' id='1'><query><item jid='a@b'/><item jid='c@d'/></query></iq>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "iq")
            let query = try #require(element.child(named: "query"))
            let items = query.children(named: "item")
            #expect(items.count == 2)
            #expect(items[0].attribute("jid") == "a@b")
            #expect(items[1].attribute("jid") == "c@d")
        }

        @Test
        func `Stanza with text content`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message><body>Hello &amp; goodbye</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hello & goodbye")
        }

        @Test
        func `Stanza with namespace`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<iq type='result'><query xmlns='jabber:iq:roster'><item jid='a@b'/></query></iq>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            let query = try #require(element.child(named: "query"))
            #expect(query.namespace == "jabber:iq:roster")
        }

        @Test
        func `Self-closing stanza`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<presence/>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "presence")
            #expect(element.children.isEmpty)
        }

        @Test
        func `Multiple stanzas in sequence`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message><body>One</body></message>",
                "<message><body>Two</body></message>",
                "<message><body>Three</body></message>"
            ])
            try #require(events.count == 4) // open + 3 stanzas
            for i in 1 ... 3 {
                let element = try #require(events[i].stanzaElement)
                #expect(element.name == "message")
            }
        }

        @Test
        func `Stanza elements in content namespace have nil namespace`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message><body>Hi</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.namespace == nil)
            #expect(element.child(named: "body")?.namespace == nil)
        }

        /// A kept element, such as another client's bookmark extension, is written out on its own, away from the
        /// ancestor that declared its attributes' prefix.
        @Test
        func `A subtree with prefixed attributes is written out well-formed and reads back unchanged`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message xmlns:o='urn:example:other'><conference xmlns='urn:xmpp:bookmarks:1'><extensions>"
                    + "<o:state o:pinned='true' xml:lang='en'><o:note>Hi</o:note></o:state>"
                    + "</extensions></conference></message>"
            ])
            let stanza = try #require(events[1].stanzaElement)
            let extensions = try #require(stanza.child(named: "conference")?.child(named: "extensions"))

            let reread = parseChunks([streamOpenTag, extensions.xmlString])

            #expect(!reread.contains { $0.isError })
            #expect(reread.count == 2)
            #expect(reread.last?.stanzaElement == extensions)
        }
    }

    struct IncrementalParsing {
        @Test
        func `Stanza split across two chunks`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message><bo",
                "dy>Hello</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hello")
        }

        @Test
        func `Stanza split mid-attribute-value`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<message type='ch",
                "at' to='user@example.com'><body>Hi</body></message>"
            ])
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.attribute("type") == "chat")
            #expect(element.attribute("to") == "user@example.com")
        }

        @Test
        func `Stream open and stanza in same chunk`() throws {
            let events = parseChunks([
                streamOpenTag + "<presence/>"
            ])
            try #require(events.count == 2)
            #expect(events[0].streamOpenedAttributes != nil)
            let element = try #require(events[1].stanzaElement)
            #expect(element.name == "presence")
        }

        @Test
        func `Byte-by-byte feeding`() throws {
            let xml = streamOpenTag + "<message><body>Hi</body></message>"
            let parser = XMPPStreamParser()
            var events: [XMLStreamEvent] = []
            for byte in xml.utf8 {
                events.append(contentsOf: parser.parse([byte]))
            }
            events.append(contentsOf: parser.close())
            try #require(events.count == 2)
            let element = try #require(events[1].stanzaElement)
            #expect(element.child(named: "body")?.textContent == "Hi")
        }

        @Test
        func `Multiple stanzas in one chunk`() throws {
            let events = parseChunks([
                streamOpenTag,
                "<presence/><message><body>Hi</body></message><iq type='get'/>"
            ])
            try #require(events.count == 4) // open + 3 stanzas
            let presence = try #require(events[1].stanzaElement)
            #expect(presence.name == "presence")
            let message = try #require(events[2].stanzaElement)
            #expect(message.name == "message")
            let iq = try #require(events[3].stanzaElement)
            #expect(iq.name == "iq")
        }
    }

    struct ErrorHandling {
        @Test
        func `Malformed XML emits error event`() {
            let events = parseChunks([
                streamOpenTag,
                "<message><body>unclosed",
                "</message>"
            ])
            #expect(events.contains { $0.isError })
        }
    }
}
