import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    await client.register(PresenceModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum PresenceModuleTests {
    struct InitialPresence {
        @Test
        func `Sends initial available presence on connect`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // After connect, PresenceModule should have sent an available presence.
            // The mock records all sent bytes — find the presence stanza.
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let hasPresence = sentStrings.contains { $0.contains("<presence") }
            #expect(hasPresence)

            await disconnectFast(client)
        }
    }

    struct DirectedPresence {
        @Test
        func `sendDirectedPresence sends to specific JID`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            let sentCountBefore = await mock.sentBytes.count

            let jid = try #require(JID.parse("contact@example.com/mobile"))
            try await module.sendDirectedPresence(to: jid, show: .away, status: "brb")

            let sentData = await mock.sentBytes
            let newSent = sentData[sentCountBefore...].map { String(decoding: $0, as: UTF8.self) }
            let directedPresence = newSent.first { $0.contains("<presence") && $0.contains("to=") }
            let unwrapped = try #require(directedPresence)
            #expect(unwrapped.contains("to=\"contact@example.com/mobile\""))
            #expect(unwrapped.contains("<show>away</show>"))
            #expect(unwrapped.contains("<status>brb</status>"))

            await disconnectFast(client)
        }

        @Test
        func `sendDirectedPresence without show or status`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            let sentCountBefore = await mock.sentBytes.count

            let jid = try #require(JID.parse("room@conference.example.com/nick"))
            try await module.sendDirectedPresence(to: jid)

            let sentData = await mock.sentBytes
            let newSent = sentData[sentCountBefore...].map { String(decoding: $0, as: UTF8.self) }
            let directedPresence = newSent.first { $0.contains("<presence") && $0.contains("to=") }
            let unwrapped = try #require(directedPresence)
            #expect(unwrapped.contains("to=\"room@conference.example.com/nick\""))
            #expect(!unwrapped.contains("<show>"))
            #expect(!unwrapped.contains("<status>"))

            await disconnectFast(client)
        }
    }

    struct PresenceTracking {
        @Test
        func `Available presence is tracked in map`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            await mock.simulateReceive(
                "<presence from='contact@example.com/mobile'><show>away</show></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let bareJID = try #require(BareJID.parse("contact@example.com"))
            let presences = module.presences(for: bareJID)
            #expect(presences.count == 1)
            #expect(presences.first?.show == .away)

            await disconnectFast(client)
        }

        @Test
        func `Unavailable presence removes entry from map`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            // First make contact available
            await mock.simulateReceive(
                "<presence from='contact@example.com/mobile'/>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let bareJID = try #require(BareJID.parse("contact@example.com"))
            #expect(!module.presences(for: bareJID).isEmpty)

            // Now make unavailable
            await mock.simulateReceive(
                "<presence type='unavailable' from='contact@example.com/mobile'/>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            #expect(module.presences(for: bareJID).isEmpty)

            await disconnectFast(client)
        }

        @Test
        func `presenceUpdated event is emitted`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceUpdated = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<presence from='contact@example.com/res'><show>dnd</show></presence>"
            )

            let events = try await eventsTask.value
            guard case let .presenceUpdated(from, presence) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceUpdated event")
            }
            #expect(from.description == "contact@example.com/res")
            #expect(presence.show == .dnd)

            await disconnectFast(client)
        }

        @Test
        func `presenceSubscriptionRequest emitted for subscribe type`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceSubscriptionRequest = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<presence type='subscribe' from='stranger@example.com'/>"
            )

            let events = try await eventsTask.value
            guard case let .presenceSubscriptionRequest(from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceSubscriptionRequest")
            }
            #expect(from.description == "stranger@example.com")

            await disconnectFast(client)
        }

        @Test
        func `handleDisconnect clears presence map`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            await mock.simulateReceive(
                "<presence from='contact@example.com/mobile'/>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let bareJID = try #require(BareJID.parse("contact@example.com"))
            #expect(!module.presences(for: bareJID).isEmpty)

            await disconnectFast(client)

            #expect(module.presences(for: bareJID).isEmpty)
        }

        @Test
        func `presences(for:) returns all resources for a bare JID`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: PresenceModule.self))

            await mock.simulateReceive(
                "<presence from='contact@example.com/mobile'/>"
            )
            await mock.simulateReceive(
                "<presence from='contact@example.com/desktop'><show>chat</show></presence>"
            )
            try? await Task.sleep(for: .milliseconds(100))

            let bareJID = try #require(BareJID.parse("contact@example.com"))
            let presences = module.presences(for: bareJID)
            #expect(presences.count == 2)

            await disconnectFast(client)
        }
    }
}
