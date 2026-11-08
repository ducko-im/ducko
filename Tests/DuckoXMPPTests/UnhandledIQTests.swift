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

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum UnhandledIQTests {
    struct ServiceUnavailable {
        @Test
        func `Replies service-unavailable for unhandled get IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <iq type='get' id='unknown-1' from='server@example.com'>\
            <query xmlns='urn:unknown:ns'/>\
            </iq>
            """)

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("type=\"error\"") && $0.contains("id=\"unknown-1\"") }
            #expect(errorIQ != nil)
            if let iq = errorIQ {
                #expect(iq.contains("service-unavailable"))
                #expect(iq.contains("to=\"server@example.com\""))
            }

            await disconnectFast(client)
        }

        @Test
        func `Replies service-unavailable for unhandled set IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <iq type='set' id='unknown-2' from='other@example.com'>\
            <command xmlns='urn:unknown:command'/>\
            </iq>
            """)

            await mock.waitForSent(count: 1)
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("type=\"error\"") && $0.contains("id=\"unknown-2\"") }
            #expect(errorIQ != nil)
            if let iq = errorIQ {
                #expect(iq.contains("service-unavailable"))
            }

            await disconnectFast(client)
        }

        @Test
        func `Does not reply for result IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <iq type='result' id='some-result'>\
            <query xmlns='urn:unknown:ns'/>\
            </iq>
            """)

            // Give time for any potential response
            try await Task.sleep(for: .milliseconds(100))
            let sentData = await mock.sentBytes
            #expect(sentData.isEmpty)

            await disconnectFast(client)
        }
    }
}
