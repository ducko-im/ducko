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
    await client.register(OOBModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Delivers an OOB IQ offer and returns the event it raised.
private func receiveOffer(
    _ mock: MockTransport, client: XMPPClient, id: String, from: String = "sender@example.com/res"
) async throws -> OOBIQOffer {
    let events = client.events
    let eventTask = Task<OOBIQOffer?, Never> {
        for await event in events {
            if case let .oobIQOfferReceived(offer) = event, offer.id == id, offer.from.description == from { return offer }
        }
        return nil
    }
    await mock.simulateReceive("""
    <iq type='set' from='\(from)' id='\(id)'>\
    <query xmlns='jabber:iq:oob'>\
    <url>https://example.com/file.txt</url>\
    </query></iq>
    """)
    return try #require(await eventTask.value)
}

private struct SendFailure: Error {}

// MARK: - Tests

enum OOBModuleTests {
    struct IncomingOffer {
        @Test
        func `Emits event for valid incoming OOB IQ offer`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let events = client.events
            let eventTask = Task<XMPPEvent?, Never> {
                for await event in events {
                    if case .oobIQOfferReceived = event { return event }
                }
                return nil
            }

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='oob-1'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/file.txt</url>\
            <desc>A text file</desc>\
            </query></iq>
            """)

            let event = await eventTask.value
            guard case let .oobIQOfferReceived(offer) = event else {
                Issue.record("Expected oobIQOfferReceived event")
                return
            }
            #expect(offer.id == "oob-1")
            #expect(offer.url == "https://example.com/file.txt")
            #expect(offer.desc == "A text file")
            #expect(offer.from.bareJID.description == "sender@example.com")

            await disconnectFast(client)
        }

        @Test
        func `Ignores IQ with wrong namespace`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.clearSentBytes()

            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='wrong-ns'>\
            <query xmlns='jabber:x:oob'>\
            <url>https://example.com/file.txt</url>\
            </query></iq>
            """)

            // The module should not handle this IQ (wrong namespace: jabber:x:oob instead of jabber:iq:oob).
            // The client should respond with service-unavailable.
            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("service-unavailable") }
            #expect(errorIQ != nil)

            await disconnectFast(client)
        }
    }

    struct AcceptOffer {
        @Test
        func `Sends IQ result on accept`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "accept-1")
            await mock.clearSentBytes()

            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.acceptOffer(offerID: offer.offerID)

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let resultIQ = sentStrings.first { $0.contains("id=\"accept-1\"") && $0.contains("type=\"result\"") }
            #expect(resultIQ != nil)
            #expect(resultIQ?.contains("to=\"sender@example.com/res\"") == true)

            await disconnectFast(client)
        }

        /// A stanza id is only unique per sender, so two senders' offers under one id are two offers, each answered to its
        /// own sender.
        @Test
        func `Offers from two senders under one stanza id are answered separately`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let first = try await receiveOffer(mock, client: client, id: "shared", from: "alice@example.com/a")
            let second = try await receiveOffer(mock, client: client, id: "shared", from: "mallory@example.com/m")
            #expect(first.offerID != second.offerID)
            await mock.clearSentBytes()

            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.acceptOffer(offerID: first.offerID)

            await mock.waitForSent(count: 1)
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.count == 1)
            #expect(sent.first?.contains("to=\"alice@example.com/a\"") == true)

            await disconnectFast(client)
        }

        /// While an answer is on its way, the offer still holds its sender's id: a repeat under that id is refused and a
        /// second answer does not start, so exactly one answer goes out.
        @Test
        func `An offer being answered keeps its id and takes no second answer`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "in-flight")
            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            await mock.clearSentBytes()
            await mock.blockSends { $0.contains("type=\"result\"") }

            let answer = Task { try await oobModule.acceptOffer(offerID: offer.offerID) }
            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='in-flight'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/again.txt</url>\
            </query></iq>
            """)
            let refused = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("id=\"in-flight\"") && $0.contains("conflict") }
            }
            #expect(refused != nil)
            try await oobModule.acceptOffer(offerID: offer.offerID)

            await mock.releaseBlockedSends()
            try await answer.value
            let results = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.contains("type=\"result\"") }
            #expect(results.count == 1)
            await disconnectFast(client)
        }

        /// An answered offer is done: a later offer under the same id is a new one, and answering the old one again sends
        /// nothing.
        @Test
        func `An answered offer frees its id and takes no second answer`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "reused")
            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.acceptOffer(offerID: offer.offerID)
            await mock.clearSentBytes()

            try await oobModule.acceptOffer(offerID: offer.offerID)
            #expect(await mock.sentBytes.isEmpty)

            let readmitted = try await boundedOutcome { _ = try await receiveOffer(mock, client: client, id: "reused") }
            #expect(readmitted != nil)
            await disconnectFast(client)
        }

        /// Nothing retries an acknowledgement, so one that could not be sent must not leave its offer holding the sender's
        /// id: the sender's next offer under it would be refused.
        @Test
        func `An acknowledgement that fails to send frees the offer's id`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "ack-failed")
            let oobModule = try #require(await client.module(ofType: OOBModule.self))

            await mock.simulateSendFailure(SendFailure())
            await #expect(throws: SendFailure.self) {
                try await oobModule.acceptOffer(offerID: offer.offerID)
            }
            await mock.simulateSendFailure(nil)

            let readmitted = try await boundedOutcome { _ = try await receiveOffer(mock, client: client, id: "ack-failed") }
            #expect(readmitted != nil)
            await disconnectFast(client)
        }

        /// While a sender still awaits the answer to an offer, a second offer under the same id would leave one answer for
        /// two offers, so it is refused and never reaches the user.
        @Test
        func `A second pending offer under the same id from the same sender is refused`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            _ = try await receiveOffer(mock, client: client, id: "dup")
            await mock.clearSentBytes()

            let events = client.events
            let nextOfferID = Task<String?, Never> {
                for await event in events {
                    if case let .oobIQOfferReceived(offer) = event { return offer.id }
                }
                return nil
            }
            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='dup'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/other.txt</url>\
            </query></iq>
            """)
            // Bounded, so a repeat that is taken instead of refused fails here rather than waiting for ever.
            let refused = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("id=\"dup\"") && $0.contains("conflict") }
            }
            #expect(refused != nil)

            // An offer under another id still arrives, so the stream is not what kept the repeat from arriving.
            await mock.simulateReceive("""
            <iq type='set' from='sender@example.com/res' id='fresh'>\
            <query xmlns='jabber:iq:oob'>\
            <url>https://example.com/fresh.txt</url>\
            </query></iq>
            """)
            #expect(await nextOfferID.value == "fresh")

            await disconnectFast(client)
        }
    }

    struct RejectOffer {
        @Test
        func `Sends not-acceptable error on reject`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "reject-1")
            await mock.clearSentBytes()

            let oobModule = try #require(await client.module(ofType: OOBModule.self))
            try await oobModule.rejectOffer(offerID: offer.offerID)

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let errorIQ = sentStrings.first { $0.contains("id=\"reject-1\"") && $0.contains("type=\"error\"") }
            #expect(errorIQ != nil)
            #expect(errorIQ?.contains("not-acceptable") == true)

            await disconnectFast(client)
        }

        /// An answer that could not be sent leaves the offer answerable, so retrying sends it rather than doing nothing.
        @Test
        func `A rejection that could not be sent can be retried`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let offer = try await receiveOffer(mock, client: client, id: "reject-retry")
            let oobModule = try #require(await client.module(ofType: OOBModule.self))

            await mock.simulateSendFailure(SendFailure())
            await #expect(throws: SendFailure.self) {
                try await oobModule.rejectOffer(offerID: offer.offerID)
            }
            await mock.simulateSendFailure(nil)
            await mock.clearSentBytes()

            // The rejection is sent before the call returns, so what went out can be read at once.
            try await oobModule.rejectOffer(offerID: offer.offerID)
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(sent.contains { $0.contains("id=\"reject-retry\"") && $0.contains("not-acceptable") })

            await disconnectFast(client)
        }
    }

    struct DiscoFeature {
        @Test
        func `Advertises jabber:iq:oob in disco features`() {
            let module = OOBModule()
            #expect(module.features.contains(XMPPNamespaces.oobIQ))
        }
    }
}
