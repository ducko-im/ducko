import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let pepIdentity = "<identity category='pubsub' type='pep'/>"
private let publishOptionsFeature = "<feature var='http://jabber.org/protocol/pubsub#publish-options'/>"
private let roomJIDString = "room@conference.example.com"

/// How the server answers a bookmark retraction.
private enum RetractAnswer {
    case result
    case error
    case none
}

/// A connected account whose server answers its own disco#info with `ownInfo`, accepts every publish and answers every
/// retraction with `retractAnswer`. Every items request is answered with `serverCopy`, the stored item, or with an
/// error of `fetchCondition` when it is nil. The bookmarks service joins and leaves rooms through a chat service.
@MainActor
private struct PublishHarness {
    let service: BookmarksService
    let accountService: AccountService
    // periphery:ignore - Held only to keep BookmarksService.chatService (a weak ref) alive
    let chatService: ChatService
    let store: MockPersistenceStore
    let transport: MockTransport
    let accountID: UUID

    func published() async -> Bool {
        await transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("<publish ") }
    }

    func joinPresences(to room: String) async -> Int {
        await transport.sentBytes.count {
            let stanza = String(decoding: $0, as: UTF8.self)
            return stanza.contains("<presence") && stanza.contains("to=\"\(room)/alice\"")
        }
    }

    /// Whether the account still means to be in `room`, which leaving it ends.
    func staysIn(_ room: BareJID) async throws -> Bool? {
        try await store.fetchConversation(jid: room.description, type: .groupchat, accountID: accountID, importSourceJID: nil)?.rejoinsOnConnect
    }
}

@MainActor
private func makePublishHarness(
    ownInfo: String, serverCopy: String? = nil, fetchCondition: String = "item-not-found", retractAnswer: RetractAnswer = .result
) async throws -> PublishHarness {
    let transport = MockTransport()
    await transport.autoReply { stanza in
        guard let id = extractIQID(from: stanza) else { return nil }
        if stanza.contains("disco#info"), stanza.contains("to=\"\(testJIDString)\"") {
            return "<iq type='result' id='\(id)'><query xmlns='http://jabber.org/protocol/disco#info'>\(ownInfo)</query></iq>"
        }
        if stanza.contains("<items ") {
            guard let serverCopy else {
                return "<iq type='error' id='\(id)'><error type='cancel'><\(fetchCondition) xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            }
            return """
            <iq type='result' id='\(id)'>\
            <pubsub xmlns='http://jabber.org/protocol/pubsub'><items node='urn:xmpp:bookmarks:1'>\(serverCopy)</items></pubsub>\
            </iq>
            """
        }
        if stanza.contains("<publish ") {
            return "<iq type='result' id='\(id)'/>"
        }
        if stanza.contains("<retract ") {
            switch retractAnswer {
            case .result: return "<iq type='result' id='\(id)'/>"
            case .error: return "<iq type='error' id='\(id)'><error type='cancel'><item-not-found xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
            case .none: return nil
            }
        }
        return nil
    }
    let store = MockPersistenceStore()
    let factory = MockXMPPClientFactory(transport: transport, modules: [ServiceDiscoveryModule(), PEPModule(), MUCModule()])
    let accountService = makeAccountService(store: store, clientFactory: factory)
    let chatService = ChatService(store: store, transcripts: MockTranscriptStore(), filterPipeline: MessageFilterPipeline())
    chatService.setAccountService(accountService)
    let bookmarksService = BookmarksService()
    bookmarksService.setAccountService(accountService)
    bookmarksService.setChatService(chatService)

    let connectTask = Task { @MainActor in
        try await accountService.createAndConnect(
            jidString: testJIDString, password: "secret", host: "example.com", port: 5222
        )
    }
    await simulateNoTLSConnect(transport)
    let accountID = try await connectTask.value
    return PublishHarness(
        service: bookmarksService, accountService: accountService, chatService: chatService, store: store, transport: transport, accountID: accountID
    )
}

struct BookmarksServicePublishTests {
    @Test(arguments: [pepIdentity, publishOptionsFeature])
    @MainActor
    func `a bookmark is not stored where the server cannot keep it private`(ownInfo: String) async throws {
        let harness = try await makePublishHarness(ownInfo: ownInfo)

        let error = await #expect(throws: BookmarksError.self) {
            try await harness.service.addBookmark(
                RoomBookmark(jidString: "room@conference.example.com", password: "secret"), accountID: harness.accountID
            )
        }
        guard case .privateStorageUnsupported? = error else {
            Issue.record("Expected privateStorageUnsupported, got \(String(describing: error))")
            return
        }

        #expect(await !harness.published())
        #expect(harness.service.bookmarks.isEmpty)
    }

    @Test
    @MainActor
    func `a bookmark is stored where the server supports PEP publish options`() async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity + publishOptionsFeature)

        try await harness.service.addBookmark(RoomBookmark(jidString: "room@conference.example.com"), accountID: harness.accountID)

        #expect(await harness.published())
        #expect(harness.service.bookmarks.map(\.jidString) == ["room@conference.example.com"])
    }

    enum KnownBookmarks: CaseIterable {
        /// The account's bookmarks were fetched.
        case fetchedList
        /// No list was fetched, as in a CLI edit, so the server's copy is asked for.
        case none
        /// The fetch failed, and a notification since named only another room. What is kept is not the whole list, so
        /// the server's copy is asked for.
        case notifiedOtherRoom
    }

    @Test(arguments: KnownBookmarks.allCases)
    @MainActor
    func `a renamed bookmark keeps another client's extensions`(known: KnownBookmarks) async throws {
        var extensions = XMLElement(name: "extensions", namespace: XMPPNamespaces.bookmarks2)
        extensions.addChild(XMLElement(name: "pinned", namespace: "urn:example:other-client"))
        var conference = XMLElement(name: "conference", namespace: XMPPNamespaces.bookmarks2)
        conference.addChild(extensions)
        let serverCopy = "<item id='\(roomJIDString)'>\(conference.xmlString)</item>"
        let harness = try await makePublishHarness(ownInfo: pepIdentity + publishOptionsFeature, serverCopy: serverCopy)
        switch known {
        case .fetchedList:
            #expect(await harness.service.loadBookmarks(accountID: harness.accountID))
        case .none:
            break
        case .notifiedOtherRoom:
            let ownJID = try #require(BareJID.parse(testJIDString))
            let other = XMLElement(name: "conference", namespace: XMPPNamespaces.bookmarks2)
            let push = XMPPEvent.pepItemsPublished(
                from: ownJID, node: XMPPNamespaces.bookmarks2, items: [PEPItem(id: "other@conference.example.com", payload: other)]
            )
            await harness.service.handleEvent(push, accountID: harness.accountID)
        }

        try await harness.service.addBookmark(RoomBookmark(jidString: roomJIDString, name: "Renamed"), accountID: harness.accountID)

        let publish = try await sentStanza(on: harness.transport, containing: "<publish ")
        #expect(publish.contains("name=\"Renamed\""))
        #expect(publish.contains(extensions.xmlString))
    }

    @Test
    @MainActor
    func `a bookmark edit that cannot read the server's copy publishes nothing`() async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity + publishOptionsFeature, fetchCondition: "internal-server-error")

        await #expect(throws: XMPPStanzaError.self) {
            try await harness.service.addBookmark(RoomBookmark(jidString: roomJIDString, name: "Renamed"), accountID: harness.accountID)
        }

        #expect(await !harness.published())
        #expect(harness.service.bookmarks.isEmpty)
    }

    @Test
    @MainActor
    func `an auto-join bookmark joins its room once when the publish result comes before its notification`() async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity + publishOptionsFeature)
        harness.service.autoJoinEnabled = true
        let bookmark = RoomBookmark(jidString: roomJIDString, autojoin: true, nickname: "alice")

        try await harness.service.addBookmark(bookmark, accountID: harness.accountID)
        #expect(await harness.joinPresences(to: roomJIDString) == 1)

        let ownJID = try #require(BareJID.parse(testJIDString))
        let room = try #require(BareJID.parse(roomJIDString))
        let notified = Bookmark(jid: room, autojoin: true, nickname: "alice").toXMLElement()
        let push = XMPPEvent.pepItemsPublished(from: ownJID, node: XMPPNamespaces.bookmarks2, items: [PEPItem(id: roomJIDString, payload: notified)])
        await harness.service.handleEvent(push, accountID: harness.accountID)

        #expect(await harness.joinPresences(to: roomJIDString) == 1)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: [true, false])
    @MainActor
    func `only a refused removal lets the notification of a retraction leave the room`(refused: Bool) async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity, retractAnswer: refused ? .error : .none)
        let room = try #require(BareJID.parse(roomJIDString))
        await harness.store.addConversation(Conversation(
            id: UUID(), accountID: harness.accountID, jid: room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
            roomNickname: "alice", rejoinsOnConnect: true, createdAt: Date()
        ))
        let service = harness.service
        let accountID = harness.accountID
        let removal = Task { @MainActor in try await service.removeBookmark(jidString: roomJIDString, accountID: accountID) }
        if !refused {
            _ = try await sentStanza(on: harness.transport, containing: "<retract ")
            await harness.transport.simulateDisconnect()
        }
        await #expect(throws: (any Error).self) { try await removal.value }

        let ownJID = try #require(BareJID.parse(testJIDString))
        let retraction = XMPPEvent.pepItemsRetracted(from: ownJID, node: XMPPNamespaces.bookmarks2, itemIDs: [roomJIDString])
        await service.handleEvent(retraction, accountID: accountID)
        // A refused removal left the bookmark in place, so its retraction was made elsewhere. One that may have gone
        // through is this device's own, which keeps the room.
        #expect(try await harness.staysIn(room) == !refused)

        // Armed: a retraction made elsewhere leaves the room.
        await service.handleEvent(retraction, accountID: accountID)
        #expect(try await harness.staysIn(room) == false)
        await harness.accountService.disconnect(accountID: accountID)
    }

    @Test
    @MainActor
    func `a removed bookmark is retracted with a notification to the account's other clients`() async throws {
        let harness = try await makePublishHarness(ownInfo: pepIdentity)

        try await harness.service.removeBookmark(jidString: roomJIDString, accountID: harness.accountID)

        let retract = try await sentStanza(on: harness.transport, containing: "<retract ")
        #expect(retract.contains("notify=\"true\""))
    }
}
