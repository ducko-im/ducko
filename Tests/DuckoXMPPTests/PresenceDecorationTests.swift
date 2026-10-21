import DuckoTestSupport
import Testing
@testable import DuckoXMPP

enum PresenceDecorationTests {
    /// Every way the client sends an available presence.
    enum PresenceSource: CaseIterable {
        case initial
        case broadcast
        case directed
        case roomJoin
        case nicknameChange

        func send(presenceModule: PresenceModule, mucModule: MUCModule) async throws {
            let room = try #require(BareJID.parse("room@conference.example.com"))
            switch self {
            case .initial:
                break
            case .broadcast:
                try await presenceModule.broadcastPresence(show: .away)
            case .directed:
                try await presenceModule.sendDirectedPresence(to: #require(JID.parse("contact@example.com")))
            case .roomJoin:
                _ = try await mucModule.joinRoom(room, nickname: "alice")
            case .nicknameChange:
                try await mucModule.changeNickname(in: room, to: "alicia")
            }
        }
    }

    /// Connects a client bound to `user@example.com/ducko` with `modules` registered.
    private static func connectedClient(registering modules: [any XMPPModule]) async throws -> (MockTransport, XMPPClient) {
        let mock = MockTransport()
        let client = XMPPClient(
            domain: "example.com",
            credentials: .init(username: "user", password: "pass"),
            transport: mock, requireTLS: false
        )
        for module in modules {
            await client.register(module)
        }

        let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
        await simulateNoTLSConnect(mock)
        try await connectTask.value
        return (mock, client)
    }

    @Test(arguments: PresenceSource.allCases)
    static func `an available presence carries both caps forms and the avatar update element`(source: PresenceSource) async throws {
        let capsModule = CapsModule()
        let presenceModule = PresenceModule(capsModule: capsModule)
        let mucModule = MUCModule(presenceModule: presenceModule)
        presenceModule.setOwnAvatarHash("avatar-hash")
        let (mock, client) = try await connectedClient(registering: [presenceModule, capsModule, mucModule])
        let sentBefore = await mock.sentBytes.count

        try await source.send(presenceModule: presenceModule, mucModule: mucModule)

        let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        let presence = try #require(sent[(source == .initial ? 0 : sentBefore)...].last { $0.contains("<presence") })
        #expect(presence.contains("<c xmlns=\"\(XMPPNamespaces.caps)\""))
        #expect(presence.contains("<c xmlns=\"\(XMPPNamespaces.caps2)\""))
        #expect(presence.contains("<x xmlns=\"\(XMPPNamespaces.vcardAvatarUpdate)\"><photo>avatar-hash</photo></x>"))

        await disconnectFast(client)
    }

    @Test(arguments: [
        ("bob@example.com/laptop", false, true),
        ("user@example.com/phone", false, false),
        ("user@example.com/phone", true, true),
        ("user@example.com/ducko", false, true)
    ])
    static func `only another own resource without the update element stops the hash being advertised`(
        from: String, carriesUpdate: Bool, advertises: Bool
    ) async throws {
        let presenceModule = PresenceModule()
        presenceModule.setOwnAvatarHash("avatar-hash")
        let (mock, client) = try await connectedClient(registering: [presenceModule])
        var received = XMPPPresence()
        received.from = JID.parse(from)
        if carriesUpdate {
            received.element.addChild(XMLElement(name: "x", namespace: XMPPNamespaces.vcardAvatarUpdate))
        }

        try presenceModule.handlePresence(received)
        try await presenceModule.broadcastPresence()

        let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        let presence = try #require(sent.last { $0.contains("<presence") })
        #expect(presence.contains("<photo>avatar-hash</photo>") == advertises)

        await disconnectFast(client)
    }

    /// The resource either goes offline or starts sending the update element.
    @Test(arguments: [true, false])
    static func `the hash is advertised again only once it is set after the last such resource stops`(goesOffline: Bool) async throws {
        let presenceModule = PresenceModule()
        presenceModule.setOwnAvatarHash("avatar-hash")
        let (_, client) = try await connectedClient(registering: [presenceModule])
        let phone = JID.parse("user@example.com/phone")
        var withholding = XMPPPresence()
        withholding.from = phone
        try presenceModule.handlePresence(withholding)
        var stopped = goesOffline ? XMPPPresence(type: .unavailable) : XMPPPresence()
        stopped.from = phone
        if !goesOffline {
            stopped.element.addChild(XMLElement(name: "x", namespace: XMPPNamespaces.vcardAvatarUpdate))
        }

        try presenceModule.handlePresence(stopped)
        var beforeReread = XMPPPresence()
        presenceModule.decorate(&beforeReread)
        presenceModule.setOwnAvatarHash("reread-hash")
        var afterReread = XMPPPresence()
        presenceModule.decorate(&afterReread)

        #expect(beforeReread.element.child(named: "x", namespace: XMPPNamespaces.vcardAvatarUpdate)?.child(named: "photo") == nil)
        #expect(afterReread.element.xmlString.contains("<photo>reread-hash</photo>"))

        await disconnectFast(client)
    }
}
