import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeBookmark(
    jid: String = "room@conference.example.com",
    name: String? = nil,
    autojoin: Bool = false,
    nickname: String? = nil,
    password: String? = nil,
    extensions: XMLElement? = nil
) -> Bookmark {
    Bookmark(
        jid: BareJID.parse(jid)!,
        name: name,
        autojoin: autojoin,
        nickname: nickname,
        password: password,
        extensions: extensions
    )
}

private func makeConferenceElement(
    name: String? = nil,
    autojoin: String? = nil,
    nickname: String? = nil,
    password: String? = nil
) -> XMLElement {
    var attrs: [String: String] = [:]
    if let name { attrs["name"] = name }
    if let autojoin { attrs["autojoin"] = autojoin }

    var conference = XMLElement(name: "conference", namespace: XMPPNamespaces.bookmarks2, attributes: attrs)

    if let nickname {
        var nick = XMLElement(name: "nick")
        nick.addText(nickname)
        conference.addChild(nick)
    }

    if let password {
        var pw = XMLElement(name: "password")
        pw.addText(password)
        conference.addChild(pw)
    }

    return conference
}

// MARK: - Tests

enum BookmarkTests {
    struct Parsing {
        @Test
        func `Parses bookmark with all fields`() {
            let payload = makeConferenceElement(
                name: "Council of Oberon",
                autojoin: "true",
                nickname: "Puck",
                password: "secret"
            )

            let bookmark = Bookmark.parse(
                itemID: "theplay@conference.shakespeare.lit",
                payload: payload
            )
            #expect(bookmark != nil)
            #expect(bookmark?.jid.description == "theplay@conference.shakespeare.lit")
            #expect(bookmark?.name == "Council of Oberon")
            #expect(bookmark?.autojoin == true)
            #expect(bookmark?.nickname == "Puck")
            #expect(bookmark?.password == "secret")
        }

        @Test
        func `Parses bookmark with minimal fields`() {
            let payload = makeConferenceElement()

            let bookmark = Bookmark.parse(
                itemID: "room@conference.example.com",
                payload: payload
            )
            #expect(bookmark != nil)
            #expect(bookmark?.jid.description == "room@conference.example.com")
            #expect(bookmark?.name == nil)
            #expect(bookmark?.autojoin == false)
            #expect(bookmark?.nickname == nil)
            #expect(bookmark?.password == nil)
        }

        @Test
        func `Parses autojoin with value 1`() {
            let payload = makeConferenceElement(autojoin: "1")

            let bookmark = Bookmark.parse(
                itemID: "room@conference.example.com",
                payload: payload
            )
            #expect(bookmark?.autojoin == true)
        }

        @Test
        func `Returns nil for wrong namespace`() {
            let payload = XMLElement(
                name: "conference",
                namespace: "wrong:namespace"
            )

            let bookmark = Bookmark.parse(
                itemID: "room@conference.example.com",
                payload: payload
            )
            #expect(bookmark == nil)
        }

        @Test
        func `Returns nil for wrong element name`() {
            let payload = XMLElement(
                name: "item",
                namespace: XMPPNamespaces.bookmarks2
            )

            let bookmark = Bookmark.parse(
                itemID: "room@conference.example.com",
                payload: payload
            )
            #expect(bookmark == nil)
        }

        @Test
        func `Returns nil for empty item ID`() {
            let payload = makeConferenceElement()

            let bookmark = Bookmark.parse(itemID: "", payload: payload)
            #expect(bookmark == nil)
        }

        @Test
        func `Returns nil for item ID with resource`() {
            let payload = makeConferenceElement()

            let bookmark = Bookmark.parse(
                itemID: "room@conference.example.com/nick",
                payload: payload
            )
            #expect(bookmark == nil)
        }
    }

    struct Building {
        @Test
        func `Builds XML with all fields`() {
            let bookmark = makeBookmark(
                name: "Council of Oberon",
                autojoin: true,
                nickname: "Puck",
                password: "secret"
            )

            let element = bookmark.toXMLElement()
            #expect(element.name == "conference")
            #expect(element.namespace == XMPPNamespaces.bookmarks2)
            #expect(element.attribute("name") == "Council of Oberon")
            #expect(element.attribute("autojoin") == "true")
            #expect(element.child(named: "nick")?.textContent == "Puck")
            #expect(element.child(named: "password")?.textContent == "secret")
        }

        @Test
        func `Builds XML with minimal fields`() {
            let bookmark = makeBookmark()

            let element = bookmark.toXMLElement()
            #expect(element.name == "conference")
            #expect(element.namespace == XMPPNamespaces.bookmarks2)
            #expect(element.attribute("name") == nil)
            #expect(element.attribute("autojoin") == nil)
            #expect(element.child(named: "nick") == nil)
            #expect(element.child(named: "password") == nil)
        }
    }

    struct RoundTrip {
        @Test
        func `Round-trip preserves all fields`() {
            var extensions = XMLElement(name: "extensions", namespace: XMPPNamespaces.bookmarks2)
            extensions.addChild(XMLElement(name: "pinned", namespace: "urn:example:other-client"))
            let original = makeBookmark(
                name: "My Room",
                autojoin: true,
                nickname: "alice",
                password: "pw123",
                extensions: extensions
            )

            let element = original.toXMLElement()
            let parsed = Bookmark.parse(
                itemID: original.jid.description,
                payload: element
            )

            #expect(parsed != nil)
            #expect(parsed?.jid == original.jid)
            #expect(parsed?.name == original.name)
            #expect(parsed?.autojoin == original.autojoin)
            #expect(parsed?.nickname == original.nickname)
            #expect(parsed?.password == original.password)
            #expect(parsed?.extensions?.child(named: "pinned", namespace: "urn:example:other-client") != nil)
        }

        /// XEP-0402 §3.4: another client's elements in `<extensions/>` are published again as they came.
        @Test
        func `Extension elements in the client namespace or in none keep it when published again`() throws {
            let event = try stanza("""
            <message from='alice@example.com'><event xmlns='http://jabber.org/protocol/pubsub#event'>\
            <items node='\(XMPPNamespaces.bookmarks2)'><item id='room@muc.example.com'>\
            <conference xmlns='\(XMPPNamespaces.bookmarks2)'><extensions>\
            <note xmlns='jabber:client'>kept</note><plain xmlns=''/><pinned xmlns='urn:example:other-client'/>\
            </extensions></conference></item></items></event></message>
            """)
            let conference = try #require(event.child(named: "event")?.child(named: "items")?.child(named: "item")?.child(named: "conference"))
            let bookmark = try #require(Bookmark.parse(itemID: "room@muc.example.com", payload: conference))

            let republished = try stanza("<message>\(bookmark.toXMLElement().xmlString)</message>")

            let extensions = try #require(republished.child(named: "conference")?.child(named: "extensions"))
            #expect(extensions.children(named: "note").map(\.namespace) == [XMPPNamespaces.client])
            #expect(extensions.children(named: "plain").map(\.namespace) == [""])
            #expect(extensions.children(named: "pinned").map(\.namespace) == ["urn:example:other-client"])
        }

        @Test
        func `Round-trip preserves minimal bookmark`() {
            let original = makeBookmark()

            let element = original.toXMLElement()
            let parsed = Bookmark.parse(
                itemID: original.jid.description,
                payload: element
            )

            #expect(parsed != nil)
            #expect(parsed?.jid == original.jid)
            #expect(parsed?.autojoin == false)
            #expect(parsed?.nickname == nil)
            #expect(parsed?.password == nil)
        }
    }

    struct PublishOptionsTests {
        @Test
        func `Publish options contain XEP-0223 fields`() {
            let options = Bookmark.publishOptions

            let formType = options.first { $0.variable == "FORM_TYPE" }
            #expect(formType != nil)
            let formTypeValues = formType?.values
            #expect(formTypeValues == ["http://jabber.org/protocol/pubsub#publish-options"])

            let persist = options.first { $0.variable == "pubsub#persist_items" }
            let persistValues = persist?.values
            #expect(persistValues == ["true"])

            let access = options.first { $0.variable == "pubsub#access_model" }
            let accessValues = access?.values
            #expect(accessValues == ["whitelist"])

            let maxItems = options.first { $0.variable == "pubsub#max_items" }
            let maxItemsValues = maxItems?.values
            #expect(maxItemsValues == ["max"])
        }
    }
}
