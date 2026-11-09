import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// A stanza-id's authority and a room's features are read from what the account and the room advertise, and count as
/// absent while unknown.
@MainActor
struct ChatServiceDiscoveredFeaturesTests {
    struct AuthorityCase: Sendable, CustomTestStringConvertible {
        let label: String
        let accountFeatures: Set<String>?
        let roomFeatures: Set<String>?
        let trustsAccount: Bool
        let trustsRoom: Bool

        var testDescription: String {
            label
        }
    }

    private static let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
    private nonisolated static let otherFeature = "urn:xmpp:mam:2"

    private let store = MockPersistenceStore()
    private let transcripts = MockTranscriptStore()
    /// Held here, since the chat service holds it weakly.
    private let accountService: AccountService
    private let chatService: ChatService
    private let accountID: UUID
    private let accountJID: BareJID

    init() async throws {
        let account = try Account(id: UUID(), jid: #require(BareJID.parse(testJIDString)), isEnabled: true, connectOnLaunch: false, createdAt: Date())
        await store.addAccount(account)
        self.accountService = makeAccountService(store: store)
        try await accountService.loadAccounts()
        self.chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        self.accountID = account.id
        self.accountJID = account.jid
    }

    @Test(arguments: [
        AuthorityCase(label: "both list sid:0", accountFeatures: [XMPPNamespaces.stanzaID], roomFeatures: [XMPPNamespaces.stanzaID], trustsAccount: true, trustsRoom: true),
        AuthorityCase(label: "only the account lists sid:0", accountFeatures: [XMPPNamespaces.stanzaID], roomFeatures: [otherFeature], trustsAccount: true, trustsRoom: false),
        AuthorityCase(label: "only the room lists sid:0", accountFeatures: [otherFeature], roomFeatures: [XMPPNamespaces.stanzaID], trustsAccount: false, trustsRoom: true),
        AuthorityCase(label: "features unknown", accountFeatures: nil, roomFeatures: nil, trustsAccount: false, trustsRoom: false)
    ])
    func `a stanza-id authority is the entity only while its own features list sid:0`(_ testCase: AuthorityCase) {
        chatService.featureSource = FixedFeatureSource(accountFeatures: testCase.accountFeatures, roomFeatures: testCase.roomFeatures)

        #expect(chatService.accountStanzaIDAuthority(accountID: accountID) == (testCase.trustsAccount ? accountJID : nil))
        #expect(chatService.roomStanzaIDAuthority(Self.room, accountID: accountID) == (testCase.trustsRoom ? Self.room : nil))
    }

    /// How a live message reaches the chat service, and so which entity's stanza-id it keeps.
    enum Arrival: CaseIterable {
        case chat, room, roomPrivateMessage, carbon, encryptedChat, encryptedRoom

        /// Whether the room, rather than the account, stamps the message's stanza-id.
        var isStampedByRoom: Bool {
            switch self {
            case .room, .encryptedRoom: true
            case .chat, .roomPrivateMessage, .carbon, .encryptedChat: false
            }
        }

        /// Whether one of the room's occupants sends the message.
        var isFromRoom: Bool {
            switch self {
            case .room, .roomPrivateMessage, .encryptedRoom: true
            case .chat, .carbon, .encryptedChat: false
            }
        }

        var isEncrypted: Bool {
            switch self {
            case .encryptedChat, .encryptedRoom: true
            case .chat, .room, .roomPrivateMessage, .carbon: false
            }
        }
    }

    /// Unknown features stand for a fresh chat service, whose account or room has not answered yet. The entity that
    /// did not stamp the message lists sid:0, so only the stamping entity's own features decide.
    @Test(arguments: Arrival.allCases, [[XMPPNamespaces.stanzaID], [otherFeature], nil] as [Set<String>?])
    func `a live message keeps its stanza-id only while the entity that stamped it lists sid:0`(arrival: Arrival, features: Set<String>?) async throws {
        let trusted: Set<String> = [XMPPNamespaces.stanzaID]
        chatService.featureSource = arrival.isStampedByRoom
            ? FixedFeatureSource(accountFeatures: trusted, roomFeatures: features)
            : FixedFeatureSource(accountFeatures: features, roomFeatures: trusted)
        try await store.upsertConversation(Conversation(
            id: UUID(), accountID: accountID, jid: Self.room, type: .groupchat,
            isPinned: false, isMuted: false, unreadCount: 0, roomNickname: "me", createdAt: Date()
        ))
        let contactJID = try #require(BareJID.parse("bob@example.com"))
        var message = XMPPMessage(type: arrival.isStampedByRoom ? .groupchat : .chat, to: .bare(accountJID), id: "m1")
        message.from = try .full(#require(arrival.isFromRoom ? FullJID(bareJID: Self.room, resourcePart: "bob") : FullJID(bareJID: contactJID, resourcePart: "phone")))
        message.body = "hi"
        if arrival.isEncrypted {
            message.element.addChild(DuckoXMPP.XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": "urn:xmpp:openpgp:0"]))
        }
        let stampedBy = arrival.isStampedByRoom ? Self.room : accountJID
        message.element.addChild(DuckoXMPP.XMLElement(
            name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "S1", "by": stampedBy.description]
        ))

        let event: XMPPEvent = switch arrival {
        case .chat, .encryptedChat: .messageReceived(message)
        case .room, .encryptedRoom: .roomMessageReceived(message)
        case .roomPrivateMessage: .mucPrivateMessageReceived(message)
        case .carbon: .messageCarbonReceived(ForwardedMessage(message: message, timestamp: nil))
        }
        await chatService.handleEvent(event, accountID: accountID)

        let stored = try #require(await transcripts.messages.first)
        #expect(stored.serverID == (features?.contains(XMPPNamespaces.stanzaID) == true ? "S1" : nil))
    }

    /// The account's disco#info as the client's own service discovery module learns it on sign-in, read through the
    /// chat service's default feature source.
    @MainActor
    struct SignedIn {
        @Test
        func `The account's answer has its stanza-ids trusted and its archive read`() async throws {
            let store = MockPersistenceStore()
            let transcripts = MockTranscriptStore()
            let transport = MockTransport()
            await transport.answerDiscoInfo(of: testJIDString, features: [XMPPNamespaces.stanzaID, XMPPNamespaces.mam])
            let accountService = makeAccountService(
                store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [ServiceDiscoveryModule(), MAMModule()])
            )
            let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
            chatService.setAccountService(accountService)
            let connection = Task { @MainActor in
                try await accountService.createAndConnect(jidString: testJIDString, password: "secret", host: "example.com", port: 5222)
            }
            await simulateNoTLSConnect(transport)
            let accountID = try await connection.value
            let accountJID = try #require(BareJID.parse(testJIDString))
            let contactJID = try #require(BareJID.parse("bob@example.com"))
            var message = XMPPMessage(type: .chat, to: .bare(accountJID), id: "m1")
            message.from = try .full(#require(FullJID(bareJID: contactJID, resourcePart: "phone")))
            message.body = "hi"
            message.element.addChild(DuckoXMPP.XMLElement(
                name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": "S1", "by": accountJID.description]
            ))

            await chatService.handleEvent(.messageReceived(message), accountID: accountID)
            let fetch = Task { @MainActor in
                try await chatService.fetchServerHistory(jid: contactJID, accountID: accountID, before: nil, limit: 50)
            }
            var answered: Set<String> = []
            let query = try await nextArchiveQuery(on: transport, answered: &answered)
            await transport.simulateReceive("<iq type='result' id='\(query.iqID)'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>")
            _ = try await fetch.value

            #expect(await transcripts.messages.map(\.serverID) == ["S1"])
            #expect(query.iq.contains("bob@example.com"))
            await accountService.disconnect(accountID: accountID)
        }
    }

    @Test
    func `a room advertises only the features its known info lists`() {
        chatService.featureSource = FixedFeatureSource(accountFeatures: [XMPPNamespaces.occupantID], roomFeatures: [XMPPNamespaces.stanzaID])
        #expect(chatService.roomAdvertises(XMPPNamespaces.stanzaID, room: Self.room, accountID: accountID))
        #expect(!chatService.roomAdvertises(XMPPNamespaces.occupantID, room: Self.room, accountID: accountID))

        chatService.featureSource = FixedFeatureSource(accountFeatures: [XMPPNamespaces.occupantID], roomFeatures: nil)
        #expect(!chatService.roomAdvertises(XMPPNamespaces.stanzaID, room: Self.room, accountID: accountID))
    }
}
