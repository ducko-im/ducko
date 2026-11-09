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
    var children: [DuckoXMPP.XMLElement] = []
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
    chatService.featureSource = FixedFeatureSource.archiving()
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
    for child in spec.children {
        element.addChild(child)
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
    stanzaID: String,
    children: [DuckoXMPP.XMLElement] = []
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
    for child in children {
        element.addChild(child)
    }
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

    struct Amendments {
        @Test
        @MainActor
        func `sent carbon with a correction edits the user's own message`() async throws {
            let fx = try await makeFixture()
            let original = makeOutgoingCarbon(from: accountBareJID, to: contactJID, body: "helo", stanzaID: "orig-1")
            await fx.chatService.handleEvent(.messageCarbonSent(original), accountID: fx.accountID)

            let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "orig-1"])
            let correction = makeOutgoingCarbon(
                from: accountBareJID, to: contactJID, body: "hello", stanzaID: "fix-1", children: [replace]
            )
            await fx.chatService.handleEvent(.messageCarbonSent(correction), accountID: fx.accountID)

            let messages = try await onlyConversationMessages(fx)
            try #require(messages.count == 1)
            #expect(messages[0].body == "hello")
            #expect(messages[0].isEdited)
            #expect(messages[0].isOutgoing)
        }

        /// The carbon names when the correction was sent, which orders it among the message's other corrections.
        @Test
        @MainActor
        func `a carbon's correction is dated by the carbon`() async throws {
            let fx = try await makeFixture()
            let original = makeOutgoingCarbon(from: accountBareJID, to: contactJID, body: "helo", stanzaID: "orig-4")
            await fx.chatService.handleEvent(.messageCarbonSent(original), accountID: fx.accountID)
            let replace = DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "orig-4"])
            let correction = makeOutgoingCarbon(from: accountBareJID, to: contactJID, body: "hello", stanzaID: "fix-4", children: [replace])

            await fx.chatService.handleEvent(
                .messageCarbonSent(ForwardedMessage(message: correction.message, timestamp: "2026-03-01T10:00:00Z")), accountID: fx.accountID
            )

            let messages = try await onlyConversationMessages(fx)
            #expect(messages.first?.editedAt == Date(xmppTimestamp: "2026-03-01T10:00:00Z"))
        }

        @Test(arguments: [false, true])
        @MainActor
        func `a carbon's correction or retraction for a chat that does not exist creates none`(isRetraction: Bool) async throws {
            let fx = try await makeFixture()
            let amendment = isRetraction
                ? DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "orig-5"])
                : DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": "orig-5"])
            let carbon = makeInboundCarbon(
                from: contactJID, to: accountBareJID, spec: InboundCarbonSpec(body: "fixed", stanzaID: "fix-5", serverStamp: nil, children: [amendment])
            )

            await fx.chatService.handleEvent(.messageCarbonReceived(carbon), accountID: fx.accountID)

            #expect(try await fx.store.fetchConversations(for: fx.accountID).isEmpty)
            #expect(await fx.transcripts.messages.isEmpty)
        }

        @Test
        @MainActor
        func `received carbon with a retraction retracts the contact's message without showing the fallback`() async throws {
            let fx = try await makeFixture()
            let original = makeInboundCarbon(
                from: contactJID, to: accountBareJID,
                spec: InboundCarbonSpec(body: "oops", stanzaID: "orig-2", serverStamp: nil)
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(original), accountID: fx.accountID)

            let retraction = makeInboundCarbon(
                from: contactJID, to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "This person attempted to retract a previous message", stanzaID: "retract-2", serverStamp: nil,
                    children: [
                        DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "orig-2"]),
                        DuckoXMPP.XMLElement(name: "fallback", namespace: XMPPNamespaces.fallbackIndication, attributes: ["for": XMPPNamespaces.messageRetract])
                    ]
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(retraction), accountID: fx.accountID)

            let messages = try await onlyConversationMessages(fx)
            try #require(messages.count == 1)
            #expect(messages[0].isRetracted)
            #expect(!messages[0].isOutgoing)
        }

        @Test(arguments: [
            DuckoXMPP.XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": XMPPNamespaces.omemo]),
            DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo)
        ])
        @MainActor
        func `encrypted carbon carrying a cleartext retraction leaves the message alone`(marker: DuckoXMPP.XMLElement) async throws {
            let fx = try await makeFixture()
            let original = makeInboundCarbon(
                from: contactJID, to: accountBareJID,
                spec: InboundCarbonSpec(body: "keep", stanzaID: "orig-3", serverStamp: nil)
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(original), accountID: fx.accountID)

            let retraction = makeInboundCarbon(
                from: contactJID, to: accountBareJID,
                spec: InboundCarbonSpec(
                    body: "encrypted fallback", stanzaID: "retract-3", serverStamp: nil,
                    children: [marker, DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "orig-3"])]
                )
            )
            await fx.chatService.handleEvent(.messageCarbonReceived(retraction), accountID: fx.accountID)

            let messages = try await onlyConversationMessages(fx)
            try #require(messages.count == 1)
            #expect(messages[0].body == "keep")
            #expect(!messages[0].isRetracted)
        }
    }
}

@MainActor
private func onlyConversationMessages(_ fx: CarbonFixture) async throws -> [ChatMessage] {
    let conversations = try await fx.store.fetchConversations(for: fx.accountID)
    try #require(conversations.count == 1)
    return try await fx.transcripts.fetchMessages(for: conversations[0].id, before: nil, limit: 50)
}

@MainActor
extension ChatServiceCarbonTests {
    @Test(arguments: [false, true], [false, true])
    static func `carbon stanza metadata survives transcript reopening`(outgoing: Bool, hasReply: Bool) async throws {
        try await verifyPersistedInboundMetadata(origin: outgoing ? .carbonSent : .carbonReceived, hasReply: hasReply)
    }
}

extension ChatServiceCarbonTests {
    struct Routing {
        private static let room = BareJID(localPart: "room", domainPart: "conference.example.com")!

        /// The live path shows these as events of their own, so a carbon of one is never a message in a chat.
        enum Unfiled: CaseIterable {
            case error, directInvite, occupantDirectInvite

            /// Whether the user has the room the carbon comes from.
            var isFromRoom: Bool {
                switch self {
                case .error, .directInvite: false
                case .occupantDirectInvite: true
                }
            }

            var carbon: ForwardedMessage {
                var element = DuckoXMPP.XMLElement(name: "message", attributes: [
                    "type": self == .error ? "error" : "chat", "from": isFromRoom ? "\(Routing.room)/bob" : "\(contactJID)/res",
                    "to": testJIDString, "id": "u1"
                ])
                var body = DuckoXMPP.XMLElement(name: "body")
                body.addText("Join us")
                element.addChild(body)
                if self != .error {
                    element.addChild(DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.mucDirectInvite, attributes: ["jid": Routing.room.description]))
                }
                return ForwardedMessage(message: XMPPMessage(element: element), timestamp: nil)
            }
        }

        /// The room the user is in, as `me`.
        @MainActor
        private static func addRoom(to fx: CarbonFixture) async -> Conversation {
            let roomChat = Conversation(
                id: UUID(), accountID: fx.accountID, jid: room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
                roomNickname: "me", createdAt: Date()
            )
            await fx.store.addConversation(roomChat)
            return roomChat
        }

        /// The carbon of a private message the user sent to the room's occupant `bob` when `isOutgoing`, else one bob sent.
        private static func privateMessageCarbon(
            isOutgoing: Bool, id: String = "pm-1", body text: String = "psst", children: [DuckoXMPP.XMLElement] = []
        ) -> XMPPEvent {
            let occupant = "\(room)/bob"
            var element = DuckoXMPP.XMLElement(name: "message", attributes: [
                "type": "chat", "from": isOutgoing ? "\(testJIDString)/res-A" : occupant, "to": isOutgoing ? occupant : testJIDString, "id": id
            ])
            var body = DuckoXMPP.XMLElement(name: "body")
            body.addText(text)
            element.addChild(body)
            element.addChild(DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.mucUser))
            for child in children {
                element.addChild(child)
            }
            let carbon = ForwardedMessage(message: XMPPMessage(element: element), timestamp: nil)
            return isOutgoing ? .messageCarbonSent(carbon) : .messageCarbonReceived(carbon)
        }

        @Test(arguments: [false, true])
        @MainActor
        func `a carbon of a room's private message is filed once in the private chat with the occupant`(isOutgoing: Bool) async throws {
            let fx = try await makeFixture()
            let roomChat = await Self.addRoom(to: fx)
            let event = Self.privateMessageCarbon(isOutgoing: isOutgoing)

            await fx.chatService.handleEvent(event, accountID: fx.accountID)
            await fx.chatService.handleEvent(event, accountID: fx.accountID)

            let conversations = try await fx.store.fetchConversations(for: fx.accountID)
            #expect(conversations.count == 2)
            let privateChat = try #require(conversations.first { $0.occupantNickname == "bob" })
            #expect(privateChat.jid == Self.room)
            let messages = try await fx.transcripts.fetchMessages(for: privateChat.id, before: nil, limit: 10)
            #expect(messages.map(\.body) == ["psst"])
            #expect(messages.first?.fromJID == "bob")
            #expect(messages.first?.isOutgoing == isOutgoing)
            #expect(try await fx.transcripts.fetchMessages(for: roomChat.id, before: nil, limit: 10).isEmpty)
        }

        /// The server authenticates the account's own address, so a sent copy names it. A received copy went through the
        /// room, which stamps its occupant id.
        @Test(arguments: [false, true])
        @MainActor
        func `a carbon of a room's private message keeps who sent it`(isOutgoing: Bool) async throws {
            let fx = try await makeFixture()
            fx.chatService.featureSource = FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.occupantID])
            _ = await Self.addRoom(to: fx)
            let occupantID = DuckoXMPP.XMLElement(name: "occupant-id", namespace: XMPPNamespaces.occupantID, attributes: ["id": "occupant-bob"])

            await fx.chatService.handleEvent(Self.privateMessageCarbon(isOutgoing: isOutgoing, children: [occupantID]), accountID: fx.accountID)

            let message = try #require(await fx.transcripts.messages.first)
            #expect(message.roomSender == (isOutgoing ? RoomSenderIdentity(realJID: accountBareJID.description) : RoomSenderIdentity(occupantID: "occupant-bob")))
        }

        /// A received copy's author is told apart by the occupant id the room stamped on it.
        @Test(arguments: [false, true])
        @MainActor
        func `A received carbon's correction of a room's private message applies only with its author's occupant id`(isSameOccupant: Bool) async throws {
            let fx = try await makeFixture()
            fx.chatService.featureSource = FixedFeatureSource.archiving(roomFeatures: [XMPPNamespaces.occupantID])
            _ = await Self.addRoom(to: fx)
            await fx.chatService.handleEvent(Self.privateMessageCarbon(isOutgoing: false, children: [Self.occupantID("occupant-bob")]), accountID: fx.accountID)

            await fx.chatService.handleEvent(
                Self.privateMessageCarbon(
                    isOutgoing: false, id: "pm-2", body: "fixed",
                    children: [Self.correction(of: "pm-1"), Self.occupantID(isSameOccupant ? "occupant-bob" : "occupant-eve")]
                ),
                accountID: fx.accountID
            )

            let original = try #require(await fx.transcripts.messages.first)
            #expect(try await fx.transcripts.findMessage(id: original.id, conversationID: original.conversationID)?.body == (isSameOccupant ? "fixed" : "psst"))
        }

        /// The server authenticates the account's own address, so a sent copy from another of the user's devices is the
        /// user's, whatever the room advertises.
        @Test
        @MainActor
        func `A sent carbon's correction of the user's own room private message applies`() async throws {
            let fx = try await makeFixture()
            _ = await Self.addRoom(to: fx)
            await fx.chatService.handleEvent(Self.privateMessageCarbon(isOutgoing: true), accountID: fx.accountID)

            await fx.chatService.handleEvent(
                Self.privateMessageCarbon(isOutgoing: true, id: "pm-2", body: "fixed", children: [Self.correction(of: "pm-1")]), accountID: fx.accountID
            )

            let original = try #require(await fx.transcripts.messages.first)
            #expect(try await fx.transcripts.findMessage(id: original.id, conversationID: original.conversationID)?.body == "fixed")
        }

        private static func occupantID(_ id: String) -> DuckoXMPP.XMLElement {
            DuckoXMPP.XMLElement(name: "occupant-id", namespace: XMPPNamespaces.occupantID, attributes: ["id": id])
        }

        private static func correction(of originalID: String) -> DuckoXMPP.XMLElement {
            DuckoXMPP.XMLElement(name: "replace", namespace: XMPPNamespaces.messageCorrect, attributes: ["id": originalID])
        }

        @Test(arguments: Unfiled.allCases)
        @MainActor
        func `a carbon of an error or an invite is not stored`(_ unfiled: Unfiled) async throws {
            let fx = try await makeFixture()
            if unfiled.isFromRoom {
                await fx.store.addConversation(Conversation(
                    id: UUID(), accountID: fx.accountID, jid: Self.room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
                    roomNickname: "me", createdAt: Date()
                ))
            }

            await fx.chatService.handleEvent(.messageCarbonReceived(unfiled.carbon), accountID: fx.accountID)

            #expect(try await fx.store.fetchConversations(for: fx.accountID).count == (unfiled.isFromRoom ? 1 : 0))
            #expect(await fx.transcripts.messages.isEmpty)
        }
    }
}
