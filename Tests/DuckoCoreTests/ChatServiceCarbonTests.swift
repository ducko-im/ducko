import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

// Service-level coverage for the carbon ingest path: extracts XEP-0359 `<stanza-id>` and dedups via
// `isDuplicateIncoming(serverID:stanzaID:fromJID:)`. Store-level predicate coverage lives in
// `FileTranscriptStoreTests`; these tests pin the ChatService wiring and the `by=` trust filter.

private let contactJID = BareJID(localPart: "bob", domainPart: "example.com")!
private let accountBareJID = BareJID.parse(testJIDString)!

/// Inbound carbon parameters. Bundled to keep `makeInboundCarbon` under the
/// project lint cap on function parameter count.
private struct InboundCarbonSpec {
    let body: String
    let stanzaID: String
    /// Pair of `(id, by)`. When `nil`, no `<stanza-id>` element is emitted.
    let serverStamp: (id: String, by: String?)?
}

@MainActor
private struct CarbonFixture {
    let chatService: ChatService
    // periphery:ignore - Held only to keep `ChatService.accountService` (a weak
    // ref) alive for the lifetime of the test. Without this strong retain, the
    // account deallocates and `accountJID(for:fallback:)` falls back to the
    // peer JID, breaking the trust-filter assertions.
    let retainedAccountService: AccountService
    let store: MockPersistenceStore
    let transcripts: MockTranscriptStore
    let accountID: UUID
}

@MainActor
private func makeFixture() async throws -> CarbonFixture {
    let store = MockPersistenceStore()
    let transcripts = MockTranscriptStore()
    let credentials = MockCredentialStore()
    let accountService = makeAccountService(store: store, credentials: credentials)
    let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
    chatService.setAccountService(accountService)
    let accountID = try await accountService.createAccount(jidString: testJIDString)
    return CarbonFixture(
        chatService: chatService,
        retainedAccountService: accountService,
        store: store,
        transcripts: transcripts,
        accountID: accountID
    )
}

/// Builds a carbon-inbound ForwardedMessage carrying an embedded XEP-0359
/// `<stanza-id>` (when `serverStamp` is non-nil).
private func makeInboundCarbon(
    from sender: BareJID,
    to recipient: BareJID,
    spec: InboundCarbonSpec
) -> ForwardedMessage {
    var element = DuckoXMPP.XMLElement(name: "message", attributes: [
        "type": "chat",
        "from": "\(sender.description)/res",
        "to": recipient.description,
        "id": spec.stanzaID
    ])
    var bodyElement = DuckoXMPP.XMLElement(name: "body")
    bodyElement.addText(spec.body)
    element.addChild(bodyElement)

    if let stamp = spec.serverStamp {
        var stanzaIDEl = DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID)
        stanzaIDEl.setAttribute("id", value: stamp.id)
        if let byJID = stamp.by {
            stanzaIDEl.setAttribute("by", value: byJID)
        }
        element.addChild(stanzaIDEl)
    }

    return ForwardedMessage(message: XMPPMessage(element: element), timestamp: nil)
}

/// Builds a carbon-sent ForwardedMessage so the outgoing row lands in the
/// transcript via `handleEvent(.messageCarbonSent(...))` — matching the
/// production `fromJID = recipient` shape used by `handleCarbon` for outgoing.
private func makeOutgoingCarbon(
    from accountJID: BareJID,
    to recipient: BareJID,
    body: String,
    stanzaID: String
) -> ForwardedMessage {
    var element = DuckoXMPP.XMLElement(name: "message", attributes: [
        "type": "chat",
        "from": "\(accountJID.description)/res-A",
        "to": recipient.description,
        "id": stanzaID
    ])
    var bodyElement = DuckoXMPP.XMLElement(name: "body")
    bodyElement.addText(body)
    element.addChild(bodyElement)
    return ForwardedMessage(message: XMPPMessage(element: element), timestamp: nil)
}

enum ChatServiceCarbonTests {
    struct ServerIDExtraction {
        @Test
        @MainActor
        func `inbound carbon stores serverID when stanza-id's by matches account JID`() async throws {
            let fx = try await makeFixture()

            let forwarded = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "hi via carbon",
                    stanzaID: "client-1",
                    serverStamp: (id: "archive-abc", by: testJIDString)
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(forwarded), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            try #require(messages.count == 1)
            #expect(messages[0].serverID == "archive-abc")
            #expect(messages[0].stanzaID == "client-1")
            #expect(messages[0].isOutgoing == false)
        }

        @Test
        @MainActor
        func `inbound carbon accepts mixed-case by that canonicalizes to account JID`() async throws {
            // RFC 7622 permits mixed-case `by` on the wire; the trust filter
            // must parse `by` as a `BareJID` (which lowercases) rather than
            // raw-string-compare against `accountJID.description`. Without
            // this, a legitimate archive stamp from a server that didn't
            // lowercase gets rejected and dedup falls through to the weaker
            // client-stanza path.
            let fx = try await makeFixture()

            let upperCaseBy = "Alice@Example.COM"
            let forwarded = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "mixed-case by",
                    stanzaID: "client-3",
                    serverStamp: (id: "archive-mixed", by: upperCaseBy)
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(forwarded), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            try #require(messages.count == 1)
            #expect(messages[0].serverID == "archive-mixed", "JID-aware `by` compare must canonicalize case")
        }

        @Test
        @MainActor
        func `inbound carbon ignores stanza-id with no by attribute`() async throws {
            let fx = try await makeFixture()

            let forwarded = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "no by",
                    stanzaID: "client-4",
                    serverStamp: (id: "untrusted", by: nil)
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(forwarded), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            try #require(messages.count == 1)
            #expect(messages[0].serverID == nil, "stanza-id without `by` cannot be trusted as a serverID")
        }

        @Test
        @MainActor
        func `inbound carbon ignores stanza-id when by does not match account JID`() async throws {
            // Peer can stamp their own `<stanza-id by="evil@host">`; the trust
            // filter (XEP-0359 §3) rejects it so `serverID` stays nil and
            // dedup falls back to the `(stanzaID, fromJID)` path.
            let fx = try await makeFixture()

            let forwarded = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "spoofed by",
                    stanzaID: "client-2",
                    serverStamp: (id: "stolen-id", by: "evil@host")
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(forwarded), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            try #require(messages.count == 1)
            #expect(messages[0].serverID == nil, "untrusted stanza-id must not be promoted to serverID")
        }
    }

    struct Dedup {
        @Test
        @MainActor
        func `inbound carbon with same serverID is deduped`() async throws {
            let fx = try await makeFixture()

            let first = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "once",
                    stanzaID: "client-1",
                    serverStamp: (id: "archive-xyz", by: testJIDString)
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(first), accountID: fx.accountID)

            // Resend the same forwarded — must be deduped via serverID.
            await fx.chatService.handleEvent(.messageCarbonReceived(first), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            #expect(messages.count == 1, "duplicate serverID must dedup at the carbon path")
        }

        @Test
        @MainActor
        func `inbound carbon with no serverID dedups by (stanzaID, fromJID) ignoring outgoing rows`() async throws {
            // Pin the regression: an outgoing alice→bob row already in the
            // transcript (with `fromJID = bob`) must not shadow a fresh
            // inbound carbon from bob carrying the same stanzaID.
            let fx = try await makeFixture()

            let outgoing = makeOutgoingCarbon(
                from: accountBareJID, to: contactJID, body: "alice→bob", stanzaID: "collide"
            )
            await fx.chatService.handleEvent(.messageCarbonSent(outgoing), accountID: fx.accountID)

            let inbound = makeInboundCarbon(
                from: contactJID,
                to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "fresh inbound",
                    stanzaID: "collide",
                    serverStamp: nil
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(inbound), accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            try #require(conversations.count == 1)
            let messages = try await fx.transcripts.fetchMessages(
                for: conversations[0].id, before: nil, limit: 50
            )
            #expect(messages.count == 2, "outgoing row must not shadow inbound on stanzaID collision")
            #expect(messages.contains { $0.body == "fresh inbound" && !$0.isOutgoing })
            #expect(messages.contains { $0.body == "alice→bob" && $0.isOutgoing })
        }
    }
}

@MainActor
extension ChatServiceCarbonTests {
    @Test(arguments: [false, true], [false, true])
    static func `carbon stanza metadata survives transcript reopening`(outgoing: Bool, hasReply: Bool) async throws {
        try await verifyPersistedInboundMetadata(origin: outgoing ? .carbonSent : .carbonReceived, hasReply: hasReply)
    }
}
