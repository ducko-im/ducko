import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Collects events from a connection until `predicate` returns `true`, with a timeout.
private func collectEvents(
    from connection: XMPPConnection,
    timeout: Duration = .seconds(2),
    until predicate: @Sendable @escaping (XMLStreamEvent) -> Bool
) async throws -> [XMLStreamEvent] {
    try await withThrowingTaskGroup(of: [XMLStreamEvent].self) { group in
        group.addTask {
            var collected: [XMLStreamEvent] = []
            for await event in connection.events {
                collected.append(event)
                if predicate(event) { break }
            }
            return collected
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPClientError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Leaves the connection where a STARTTLS handshake upgrades: plaintext stream open and the TLS-namespace `<proceed/>`
/// from `proceedChunk` read.
private func connectThroughProceed(
    _ connection: XMPPConnection,
    mock: MockTransport,
    proceedChunk: String
) async throws -> EventReader {
    try await connection.connect(host: "example.com", port: 5222)
    let reader = EventReader(connection.events)
    await mock.simulateReceive(testServerStreamOpen)
    await mock.simulateReceive(proceedChunk)
    guard case .streamOpened = try await reader.awaitNextEvent() else {
        throw XMPPClientError.unexpectedStreamState("Expected stream opened")
    }
    let proceed = try await reader.awaitStanza()
    try #require(XMPPConnection.isTLSProceed(proceed))
    return reader
}

// MARK: - Tests

enum XMPPConnectionTests {
    struct ConnectionLifecycle {
        @Test
        func `Connect establishes transport`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let isConnected = await mock.isConnected
            let host = await mock.connectedHost
            let port = await mock.connectedPort
            #expect(isConnected)
            #expect(host == "example.com")
            #expect(port == 5222)

            await connection.disconnect()
        }

        @Test
        func `Disconnect stops transport and finishes events`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)
            await connection.disconnect()

            let isConnected = await mock.isConnected
            #expect(!isConnected)

            // Event stream should terminate
            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }
            #expect(events.isEmpty)
        }
    }

    struct DataReceiving {
        @Test
        func `Received bytes emit XML stream events`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            // Simulate server sending stream open + a stanza
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("<message><body>Hello</body></message>")
            await mock.simulateDisconnect()

            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }

            // Should have at least streamOpened + stanzaReceived
            let hasStreamOpen = events.contains { $0.streamOpenedAttributes != nil }
            let stanzas = events.compactMap(\.stanzaElement)
            #expect(hasStreamOpen)
            #expect(stanzas.count == 1)
            #expect(stanzas[0].name == "message")
            #expect(stanzas[0].child(named: "body")?.textContent == "Hello")

            await connection.disconnect()
        }

        @Test
        func `Incremental chunks produce correct stanzas`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            // Send stream open + a stanza split across chunks
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("<message><bo")
            await mock.simulateReceive("dy>Split</body></message>")
            await mock.simulateDisconnect()

            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }

            let stanzas = events.compactMap(\.stanzaElement)
            #expect(stanzas.count == 1)
            #expect(stanzas[0].child(named: "body")?.textContent == "Split")

            await connection.disconnect()
        }
    }

    struct TLSUpgrade {
        @Test
        func `Upgrade resets parser and resumes receiving`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let isTLSBefore = await mock.isTLSUpgraded
            #expect(!isTLSBefore)

            try await connection.upgradeTLS(serverName: "example.com")

            let isTLSAfter = await mock.isTLSUpgraded
            #expect(isTLSAfter)

            await connection.disconnect()
        }

        @Test
        func `Events flow after TLS upgrade`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)
            try await connection.upgradeTLS(serverName: "example.com")

            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("<message><body>After TLS</body></message>")

            let events = try await collectEvents(from: connection) {
                $0.stanzaElement != nil
            }

            let stanza = try #require(events.compactMap(\.stanzaElement).first)
            #expect(stanza.child(named: "body")?.textContent == "After TLS")

            await connection.disconnect()
        }

        @Test
        func `Plaintext fed after proceed fails the upgrade`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)
            _ = try await connectThroughProceed(connection, mock: mock, proceedChunk: testProceed)

            await mock.simulateReceive(testInjectedMessage)
            await expectTLSNegotiationFailure(reason: "The server sent unexpected data after agreeing to start TLS", mock: mock) {
                try await connection.upgradeTLS(serverName: "example.com")
            }

            await connection.disconnect()
        }

        @Test
        func `Plaintext in the proceed chunk fails the upgrade`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)
            // The message is parsed with the proceed before the upgrade starts, so only the post-proceed record catches it.
            _ = try await connectThroughProceed(connection, mock: mock, proceedChunk: testProceed + testInjectedMessage)

            await expectTLSNegotiationFailure(reason: "The server sent unexpected data after agreeing to start TLS", mock: mock) {
                try await connection.upgradeTLS(serverName: "example.com")
            }

            await connection.disconnect()
        }

        @Test(arguments: ["  \n", "<mess"])
        func `Bytes after proceed that parse to nothing are discarded`(trailing: String) async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)
            let reader = try await connectThroughProceed(connection, mock: mock, proceedChunk: testProceed + trailing)

            try await connection.upgradeTLS(serverName: "example.com")
            await mock.simulateReceive(testServerStreamOpen)
            await mock.simulateReceive("<message><body>After TLS</body></message>")

            guard case .streamOpened = try await reader.awaitNextEvent() else {
                Issue.record("Expected the post-TLS stream opening")
                return
            }
            let stanza = try await reader.awaitStanza()
            #expect(stanza.child(named: "body")?.textContent == "After TLS")

            await connection.disconnect()
        }

        @Test
        func `A stray proceed without an upgrade does not affect delivery`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)
            let reader = try await connectThroughProceed(connection, mock: mock, proceedChunk: testProceed + testInjectedMessage)

            let message = try await reader.awaitStanza()
            #expect(message.child(named: "body")?.textContent == "Injected")

            await connection.disconnect()
        }

        @Test
        func `Disconnect before the upgrade throws`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)
            try await connection.connect(host: "example.com", port: 5222)
            await connection.disconnect()

            let error = await #expect(throws: XMPPClientError.self) {
                try await connection.upgradeTLS(serverName: "example.com")
            }
            guard case .notConnected = error else {
                Issue.record("Expected notConnected, got \(String(describing: error))")
                return
            }
            let isTLS = await mock.isTLSUpgraded
            #expect(!isTLS)
            var events: [XMLStreamEvent] = []
            for await event in connection.events {
                events.append(event)
            }
            #expect(events.isEmpty)
        }
    }

    struct Sending {
        @Test
        func `Send forwards bytes to transport`() async throws {
            let mock = MockTransport()
            let connection = XMPPConnection(transport: mock)

            try await connection.connect(host: "example.com", port: 5222)

            let bytes: [UInt8] = Array("<presence/>".utf8)
            try await connection.send(bytes)

            let sent = await mock.sentBytes
            #expect(sent.count == 1)
            #expect(sent[0] == bytes)

            await connection.disconnect()
        }
    }
}

// MARK: - SRV Record Tests

struct SRVRecordTests {
    @Test
    func `Sorts by priority then weight`() {
        let records = [
            SRVRecord(priority: 20, weight: 50, port: 5222, target: "low-pri.example.com", directTLS: false),
            SRVRecord(priority: 10, weight: 30, port: 5222, target: "high-pri-low-weight.example.com", directTLS: false),
            SRVRecord(priority: 10, weight: 70, port: 5222, target: "high-pri-high-weight.example.com", directTLS: false)
        ]

        let sorted = records.sorted()
        #expect(sorted[0].target == "high-pri-high-weight.example.com")
        #expect(sorted[1].target == "high-pri-low-weight.example.com")
        #expect(sorted[2].target == "low-pri.example.com")
    }

    @Test
    func `Sorts mixed directTLS and STARTTLS records by priority then weight`() {
        let records = [
            SRVRecord(priority: 20, weight: 50, port: 5222, target: "starttls.example.com", directTLS: false),
            SRVRecord(priority: 10, weight: 30, port: 5223, target: "directtls.example.com", directTLS: true),
            SRVRecord(priority: 10, weight: 70, port: 5222, target: "starttls-high.example.com", directTLS: false)
        ]

        let sorted = records.sorted()
        #expect(sorted[0].target == "starttls-high.example.com")
        #expect(sorted[0].directTLS == false)
        #expect(sorted[1].target == "directtls.example.com")
        #expect(sorted[1].directTLS == true)
        #expect(sorted[2].target == "starttls.example.com")
    }

    @Test(arguments: [true, false])
    func `A "." answer with no usable record rules out the address fallback`(directTLS: Bool) {
        let notOffered = SRVRecord(priority: 0, weight: 0, port: 0, target: ".", directTLS: directTLS)

        let records = XMPPSRVLookup.connectionOrder(for: [notOffered], domain: "example.com")

        #expect(records.isEmpty)
    }

    @Test
    func `A "." Direct TLS answer leaves the STARTTLS records`() {
        let notOffered = SRVRecord(priority: 0, weight: 0, port: 0, target: ".", directTLS: true)
        let starttls = SRVRecord(priority: 10, weight: 0, port: 5222, target: "xmpp.example.com", directTLS: false)

        let records = XMPPSRVLookup.connectionOrder(for: [notOffered, starttls], domain: "example.com")

        #expect(records == [starttls])
    }

    @Test
    func `Fallback on empty results returns domain:5222`() async {
        // Use an invalid domain that will definitely fail SRV lookup
        let records = await XMPPSRVLookup.resolve(
            domain: "this-domain-does-not-exist-12345.invalid",
            timeout: .seconds(2)
        )
        #expect(records.count == 1)
        #expect(records[0].port == 5222)
        #expect(records[0].target == "this-domain-does-not-exist-12345.invalid")
        #expect(records[0].directTLS == false)
    }
}
