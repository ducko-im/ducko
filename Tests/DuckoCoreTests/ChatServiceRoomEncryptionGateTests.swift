import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

private let room = BareJID(localPart: "room", domainPart: "conference.example.com")!

/// An encrypted room message goes out only when the room shows its members' real addresses and its member lists can be
/// read (XEP-0384).
@MainActor
struct ChatServiceRoomEncryptionGateTests {
    @Test func `an encrypted send to a room not known to be non-anonymous is refused before anything is sent`() async throws {
        let harness = try await RoomHarness.connect(roomFeatures: [], refusedAffiliation: nil)

        await #expect {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } throws: { error in
            if case ChatService.ChatServiceError.omemoRoomNotNonAnonymous(roomJID: room) = error { true } else { false }
        }

        await harness.expectNothingSent()
    }

    @Test func `an encrypted send to a room whose admin list cannot be read is refused before anything is sent`() async throws {
        let harness = try await RoomHarness.connect(roomFeatures: [XMPPNamespaces.mucNonAnonymous], refusedAffiliation: "admin")

        await #expect {
            try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)
        } throws: { error in
            if case ChatService.ChatServiceError.roomMemberListUnavailable(roomJID: room) = error { true } else { false }
        }

        await harness.expectNothingSent()
    }

    @Test func `an encrypted send to a room whose features are not known yet asks the room before deciding`() async throws {
        let harness = try await EncryptedSendHarness.connect()
        harness.chatService.featureSource = UnaskedRoomFeatureSource()

        try await harness.chatService.sendGroupMessage(to: room, body: "secret", accountID: harness.accountID)

        let sent = await harness.transport.waitForSent { $0.hasPrefix("<message") && $0.contains("<encrypted") }
        #expect(sent != nil)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}

/// Rooms that list `muc_nonanonymous` when asked, whose features are not known before, as after a rejoin whose query
/// went unanswered.
@MainActor
private struct UnaskedRoomFeatureSource: DiscoveredFeatureSource {
    let features = FixedFeatureSource(roomFeatures: [XMPPNamespaces.mucNonAnonymous])

    func accountInfo(accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await features.accountInfo(accountID: accountID)
    }

    func roomInfo(_ room: BareJID, accountID: UUID) async -> ServiceDiscoveryModule.InfoResult? {
        await features.roomInfo(room, accountID: accountID)
    }

    func knownAccountInfo(accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        features.knownAccountInfo(accountID: accountID)
    }

    func knownRoomInfo(_ room: BareJID, accountID: UUID) -> ServiceDiscoveryModule.InfoResult? {
        nil
    }
}

/// A connected account with an encrypted room whose disco#info lists `roomFeatures`, talking to a server that refuses
/// the room's `refusedAffiliation` list, lists bob as a member, and answers every PubSub request with nothing.
@MainActor
private struct RoomHarness {
    let transport: MockTransport
    let accountService: AccountService
    let chatService: ChatService
    let transcripts: MockTranscriptStore
    // periphery:ignore - Held only to keep ChatService.omemoService (a weak ref) alive
    let omemoService: OMEMOService
    let accountID: UUID
    let connection: Task<Void, any Error>

    static func connect(roomFeatures: Set<String>, refusedAffiliation: String?) async throws -> RoomHarness {
        let store = MockPersistenceStore()
        let transport = MockTransport()
        await transport.autoReply { stanza in reply(to: stanza, refusing: refusedAffiliation) }
        let omemoModule = OMEMOModule(pepModule: PEPModule())
        omemoModule.markIdentityUnavailable()
        let accountService = makeAccountService(
            store: store, clientFactory: MockXMPPClientFactory(transport: transport, modules: [MUCModule(), omemoModule])
        )
        let transcripts = MockTranscriptStore()
        let chatService = ChatService(store: store, transcripts: transcripts, filterPipeline: MessageFilterPipeline())
        chatService.setAccountService(accountService)
        chatService.featureSource = FixedFeatureSource(roomFeatures: roomFeatures)
        let omemoService = OMEMOService(omemoStore: MockOMEMOStore())
        omemoService.setAccountService(accountService)
        chatService.setOMEMOService(omemoService)
        let accountID = try await accountService.createAccount(jidString: testJIDString, requireTLS: false)
        let (_, connection) = try await driveMockConnect(accountService, accountID: accountID, transport: transport)
        await store.addConversation(Conversation(
            id: UUID(), accountID: accountID, jid: room, type: .groupchat, isPinned: false, isMuted: false, unreadCount: 0,
            roomNickname: "me", encryptionEnabled: true, createdAt: Date()
        ))
        try await chatService.loadConversations(for: accountID)
        return RoomHarness(
            transport: transport, accountService: accountService, chatService: chatService, transcripts: transcripts,
            omemoService: omemoService, accountID: accountID, connection: connection
        )
    }

    /// No message went out and none was stored. Disconnects the account.
    func expectNothingSent() async {
        let sent = await transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        #expect(await transcripts.messages.isEmpty)
        await accountService.disconnect(accountID: accountID)
        _ = await connection.result
    }

    /// The server's answer to a room-affiliation or PubSub request; nil for anything else.
    private nonisolated static func reply(to stanza: String, refusing refusedAffiliation: String?) -> String? {
        guard stanza.hasPrefix("<iq"), let id = value(of: " id=\"", in: stanza) else { return nil }
        let from = value(of: " to=\"", in: stanza).map { " from=\"\($0)\"" } ?? ""
        if stanza.contains("muc#admin") {
            let affiliation = value(of: "affiliation=\"", in: stanza)
            if affiliation == refusedAffiliation {
                return "<iq type=\"error\" id=\"\(id)\"\(from)><error type=\"auth\"><forbidden xmlns=\"urn:ietf:params:xml:ns:xmpp-stanzas\"/></error></iq>"
            }
            let member = affiliation == "member" ? "<item affiliation=\"member\" jid=\"bob@example.com\"/>" : ""
            return "<iq type=\"result\" id=\"\(id)\"\(from)><query xmlns=\"http://jabber.org/protocol/muc#admin\">\(member)</query></iq>"
        }
        if stanza.contains(XMPPNamespaces.pubsub) {
            return "<iq type=\"result\" id=\"\(id)\"\(from)/>"
        }
        return nil
    }

    /// The text from the first `prefix` in `stanza` up to the next quote.
    private nonisolated static func value(of prefix: String, in stanza: String) -> String? {
        guard let start = stanza.range(of: prefix), let end = stanza[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(stanza[start.upperBound ..< end])
    }
}
