import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makePresenceClient(mock: MockTransport) async throws -> (XMPPClient, PresenceModule) {
    let presenceModule = PresenceModule()
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(presenceModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return (client, presenceModule)
}

// MARK: - Tests

enum AvatarTests {
    struct VCardAvatarHashPresence {
        @Test
        func `Presence with vCard avatar hash emits vcardAvatarHashReceived`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makePresenceClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .vcardAvatarHashReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='alice@example.com/resource'>
            <x xmlns='vcard-temp:x:update'>
            <photo>abc123def456</photo>
            </x>
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .vcardAvatarHashReceived(from, hash) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected vcardAvatarHashReceived")
            }
            #expect(from.description == "alice@example.com")
            #expect(hash == "abc123def456")

            await disconnectFast(client)
        }

        @Test
        func `Presence with empty photo element emits nil hash`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makePresenceClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .vcardAvatarHashReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <presence from='alice@example.com/resource'>
            <x xmlns='vcard-temp:x:update'>
            <photo/>
            </x>
            </presence>
            """)

            let events = try await eventsTask.value
            guard case let .vcardAvatarHashReceived(_, hash) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected vcardAvatarHashReceived")
            }
            #expect(hash == nil)

            await disconnectFast(client)
        }

        @Test
        func `Presence without x element does not emit vcardAvatarHashReceived`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makePresenceClient(mock: mock)

            await mock.simulateReceive("""
            <presence from='bob@example.com/laptop'>
            <show>away</show>
            </presence>
            """)

            // Then disconnect to collect all events
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await disconnectFast(client)
            let events = try await eventsTask.value

            let hasAvatarEvent = events.contains { event in
                if case .vcardAvatarHashReceived = event { return true }
                return false
            }
            #expect(!hasAvatarEvent)
        }

        @Test
        func `Unavailable presence with x element does not emit vcardAvatarHashReceived`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makePresenceClient(mock: mock)

            // Send unavailable presence with vcard update — should be ignored per XEP-0153
            await mock.simulateReceive("""
            <presence from='alice@example.com/resource' type='unavailable'>
            <x xmlns='vcard-temp:x:update'>
            <photo>abc123</photo>
            </x>
            </presence>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await disconnectFast(client)
            let events = try await eventsTask.value

            let hasAvatarEvent = events.contains { event in
                if case .vcardAvatarHashReceived = event { return true }
                return false
            }
            #expect(!hasAvatarEvent)
        }
    }

    struct OutgoingPresenceAvatarHash {
        @Test
        func `BroadcastPresence includes vCard avatar hash when set`() async throws {
            let mock = MockTransport()
            let (client, presenceModule) = try await makePresenceClient(mock: mock)

            presenceModule.setOwnAvatarHash("deadbeef1234")
            await mock.clearSentBytes()

            try await presenceModule.broadcastPresence()

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sentString.contains("vcard-temp:x:update"))
            #expect(sentString.contains("<photo>deadbeef1234</photo>"))

            await disconnectFast(client)
        }

        @Test
        func `BroadcastPresence includes empty photo when hash is nil`() async throws {
            let mock = MockTransport()
            let (client, presenceModule) = try await makePresenceClient(mock: mock)

            presenceModule.setOwnAvatarHash(nil)
            await mock.clearSentBytes()

            try await presenceModule.broadcastPresence()

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sentString.contains("vcard-temp:x:update"))
            #expect(sentString.contains("<photo/>"))

            await disconnectFast(client)
        }

        @Test
        func `Initial presence makes no avatar claim before the own hash is set`() async throws {
            let mock = MockTransport()
            let (client, _) = try await makePresenceClient(mock: mock)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sentString.contains("vcard-temp:x:update"))
            #expect(!sentString.contains("<photo"))

            await disconnectFast(client)
        }

        @Test
        func `Initial presence on connect includes vCard avatar hash element`() async throws {
            let mock = MockTransport()
            let presenceModule = PresenceModule()
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(presenceModule)

            // Set hash before connect
            presenceModule.setOwnAvatarHash("cafebabe")

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            // The initial presence is sent during handleConnect
            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()

            #expect(sentString.contains("vcard-temp:x:update"))
            #expect(sentString.contains("<photo>cafebabe</photo>"))

            await disconnectFast(client)
        }
    }

    struct PEPAvatarMetadata {
        @Test
        func `PEP avatar metadata notification flows through pepItemsPublished`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            pepModule.registerNotifyInterest(XMPPNamespaces.avatarMetadata)

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(pepModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .pepItemsPublished = event { return true }
                    return false
                }
            }

            let testHash = "abc123def456789012345678901234567890abcd"
            await mock.simulateReceive("""
            <message from='alice@example.com' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='urn:xmpp:avatar:metadata'>
            <item id='\(testHash)'><metadata xmlns='urn:xmpp:avatar:metadata'><info id='\(testHash)' type='image/png' bytes='1024'/></metadata></item>
            </items>
            </event>
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .pepItemsPublished(from, node, items) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected pepItemsPublished")
            }
            #expect(from.description == "alice@example.com")
            #expect(node == XMPPNamespaces.avatarMetadata)
            #expect(items.count == 1)
            #expect(items.first?.payload.name == "metadata")

            // Verify metadata info attributes
            let info = items.first?.payload.child(named: "info")
            #expect(info?.attribute("id") == testHash)
            #expect(info?.attribute("type") == "image/png")
            #expect(info?.attribute("bytes") == "1024")

            await disconnectFast(client)
        }

        @Test
        func `Empty PEP avatar metadata indicates avatar disabled`() async throws {
            let mock = MockTransport()
            let pepModule = PEPModule()
            pepModule.registerNotifyInterest(XMPPNamespaces.avatarMetadata)

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(pepModule)

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connectTask.value

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .pepItemsPublished = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='alice@example.com' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='urn:xmpp:avatar:metadata'>
            <item id='current'><metadata xmlns='urn:xmpp:avatar:metadata'/></item>
            </items>
            </event>
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .pepItemsPublished(_, _, items) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected pepItemsPublished")
            }
            // Empty metadata — no <info> child
            let info = items.first?.payload.child(named: "info")
            #expect(info == nil)

            await disconnectFast(client)
        }
    }
}
