import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// A module whose server lists one search service and answers every search with `results`, or with the error
/// `searchError` holds.
private func makeSearchModule(
    results: [XMLElement.Node] = [], searchError: XMPPStanzaError? = nil, sentIQs: OSAllocatedUnfairLock<[XMPPIQ]> = .init(initialState: [])
) -> ChannelSearchModule {
    let module = ChannelSearchModule()
    module.setUp(makeStubModuleContext(sendIQ: { iq, _ in
        sentIQs.withLock { $0.append(iq) }
        switch iq.childElement?.namespace {
        case XMPPNamespaces.discoItems:
            return XMLElement(name: "query", namespace: XMPPNamespaces.discoItems, children: [
                .element(XMLElement(name: "item", attributes: ["jid": "search.example.com"]))
            ])
        case XMPPNamespaces.discoInfo:
            return XMLElement(name: "query", namespace: XMPPNamespaces.discoInfo, children: [
                .element(XMLElement(name: "feature", attributes: ["var": "urn:xmpp:channel-search:0:search"]))
            ])
        default:
            if let searchError { throw searchError }
            return XMLElement(name: "result", namespace: "urn:xmpp:channel-search:0:search", children: results)
        }
    }))
    return module
}

struct ChannelSearchModuleTests {
    @Test
    func `Search finds the service by its search feature and submits the search-params form`() async throws {
        let sentIQs = OSAllocatedUnfairLock<[XMPPIQ]>(initialState: [])
        let module = makeSearchModule(sentIQs: sentIQs)

        _ = try await module.search(ChannelSearchModule.SearchQuery(keyword: "ducks"))

        let searchIQ = try #require(sentIQs.withLock { $0.last })
        let search = try #require(searchIQ.childElement)
        #expect(search.name == "search")
        #expect(search.namespace == "urn:xmpp:channel-search:0:search")
        let formType = try #require(search.child(named: "x").map(parseDataForm)?.fields.first { $0.variable == "FORM_TYPE" })
        #expect(formType.values == ["urn:xmpp:channel-search:0:search-params"])
    }

    @Test
    func `is-open is read as a flag element, with boolean text also understood`() async throws {
        let module = makeSearchModule(results: [
            .element(XMLElement(name: "item", attributes: ["address": "open@muc.example.com"], children: [
                .element(XMLElement(name: "is-open"))
            ])),
            .element(XMLElement(name: "item", attributes: ["address": "closed@muc.example.com"])),
            .element(XMLElement(name: "item", attributes: ["address": "listed@muc.example.com"], children: [
                .element(XMLElement(name: "is-open", children: [.text("false")]))
            ]))
        ])

        let result = try await module.search(ChannelSearchModule.SearchQuery(keyword: "ducks"))

        #expect(result.items.map(\.isOpen) == [true, nil, false])
    }

    @Test(arguments: [
        (#"<rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="30"/>"#, 30 as Int?),
        (#"<rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="1.5"/>"#, 2),
        (#"<rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="-5"/>"#, nil),
        (#"<rate-limit xmlns="urn:xmpp:channel-search:0:error"/>"#, nil),
        (#"<rate-limit xmlns="urn:xmpp:channel-search:0:error" retry-after="soon"/>"#, nil)
    ])
    func `A rate-limited search reports the retry-after seconds the service names`(rateLimit: String, retryAfter: Int?) async throws {
        let module = try makeSearchModule(searchError: searchError(resourceConstraintWith: rateLimit))

        let error = await #expect(throws: ChannelSearchModule.ChannelSearchError.self) {
            try await module.search(ChannelSearchModule.SearchQuery(keyword: "ducks"))
        }

        guard case let .rateLimited(reported) = error else {
            Issue.record("Expected a rate limit, got \(String(describing: error))")
            return
        }
        #expect(reported == retryAfter)
    }

    @Test
    func `A resource constraint without a rate limit stays a stanza error`() async throws {
        let module = try makeSearchModule(searchError: searchError(resourceConstraintWith: ""))

        await #expect(throws: XMPPStanzaError.self) {
            try await module.search(ChannelSearchModule.SearchQuery(keyword: "ducks"))
        }
    }

    private func searchError(resourceConstraintWith applicationCondition: String) throws -> XMPPStanzaError {
        let iq = try stanza("""
        <iq type="error" id="s1" from="search.example.com"><error type="wait">\
        <resource-constraint xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/>\
        \(applicationCondition)</error></iq>
        """)
        return try #require(XMPPStanzaError.parse(from: iq.child(named: "error")))
    }

    @Test
    func `SearchQuery defaults`() {
        let query = ChannelSearchModule.SearchQuery(keyword: "test")
        #expect(query.keyword == "test")
        #expect(query.searchInName)
        #expect(query.searchInDescription)
        #expect(query.sortKey == nil)
        #expect(query.maxResults == nil)
        #expect(query.after == nil)
    }

    @Test
    func `ChannelInfo creation`() throws {
        let jid = try #require(BareJID.parse("room@conference.example.com"))
        let info = ChannelSearchModule.ChannelInfo(
            address: jid,
            name: "Test Room",
            userCount: 42,
            isOpen: true,
            description: "A test room"
        )
        #expect(info.address == jid)
        #expect(info.name == "Test Room")
        #expect(info.userCount == 42)
        #expect(info.isOpen == true)
        #expect(info.description == "A test room")
    }

    @Test
    func `SearchResult empty`() {
        let result = ChannelSearchModule.SearchResult(items: [], totalCount: nil, lastID: nil)
        #expect(result.items.isEmpty)
        #expect(result.totalCount == nil)
        #expect(result.lastID == nil)
    }

    @Test
    func `SearchResult with pagination`() throws {
        let jid = try #require(BareJID.parse("room@conference.example.com"))
        let item = ChannelSearchModule.ChannelInfo(
            address: jid, name: "Room", userCount: 5, isOpen: true, description: nil
        )
        let result = ChannelSearchModule.SearchResult(
            items: [item], totalCount: 100, lastID: "last-item-id"
        )
        #expect(result.items.count == 1)
        #expect(result.totalCount == 100)
        #expect(result.lastID == "last-item-id")
    }

    @Test
    func `Module advertises no features`() {
        #expect(ChannelSearchModule().features.isEmpty)
    }
}
