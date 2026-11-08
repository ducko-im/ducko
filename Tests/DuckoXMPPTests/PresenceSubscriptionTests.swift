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

enum PresenceSubscriptionTests {
    struct Approved {
        @Test
        func `subscribed presence emits presenceSubscriptionApproved`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceSubscriptionApproved = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<presence type='subscribed' from='contact@example.com'/>"
            )

            let events = try await eventsTask.value
            guard case let .presenceSubscriptionApproved(from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceSubscriptionApproved")
            }
            #expect(from.description == "contact@example.com")

            await disconnectFast(client)
        }
    }

    struct Revoked {
        @Test
        func `unsubscribed presence emits presenceSubscriptionRevoked`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .presenceSubscriptionRevoked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<presence type='unsubscribed' from='contact@example.com'/>"
            )

            let events = try await eventsTask.value
            guard case let .presenceSubscriptionRevoked(from) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected presenceSubscriptionRevoked")
            }
            #expect(from.description == "contact@example.com")

            await disconnectFast(client)
        }
    }

    struct Ignored {
        @Test(arguments: ["unsubscribe", "probe"])
        func `presence type does not emit subscription events`(_ type: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.simulateReceive(
                "<presence type='\(type)' from='contact@example.com'/>"
            )
            try? await Task.sleep(for: .milliseconds(200))

            // Send a known event to flush the stream
            await mock.simulateReceive(
                "<presence from='other@example.com'/>"
            )

            let events = try await collectEvents(from: client) { event in
                if case .presenceUpdated = event { return true }
                return false
            }

            let hasSubscriptionEvent = events.contains { event in
                if case .presenceSubscriptionApproved = event { return true }
                if case .presenceSubscriptionRevoked = event { return true }
                if case .presenceSubscriptionRequest = event { return true }
                return false
            }
            #expect(!hasSubscriptionEvent)

            await disconnectFast(client)
        }
    }
}
