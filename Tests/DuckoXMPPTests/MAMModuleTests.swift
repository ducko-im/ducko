import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func makeConnectedClient(mock: MockTransport) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(MAMModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private struct MAMIQInfo {
    let iq: String
    let iqID: String
    let queryID: String
}

/// Finds the MAM IQ from sent bytes and returns it along with its iq ID and queryid.
private func findMAMIQ(mock: MockTransport) async -> MAMIQInfo? {
    let sentData = await mock.sentBytes
    let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
    guard let mamIQ = sentStrings.first(where: { $0.contains("urn:xmpp:mam:2") }),
          let iqID = extractIQID(from: mamIQ),
          let queryID = extractQueryID(from: mamIQ) else {
        return nil
    }
    return MAMIQInfo(iq: mamIQ, iqID: iqID, queryID: queryID)
}

/// Sends a simple empty fin response to complete a MAM query.
private func sendEmptyFin(mock: MockTransport, iqID: String) async {
    await mock.simulateReceive(
        "<iq type='result' id='\(iqID)'><fin xmlns='urn:xmpp:mam:2' complete='true'><set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin></iq>"
    )
}

// MARK: - Tests

enum MAMModuleTests {
    struct QueryConstruction {
        @Test
        func `queryMessages sends correct IQ with filters and RSM pagination`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("contact@example.com"))
            let queryTask = Task {
                try await module.queryMessages(
                    with: jid, start: "2026-01-01T00:00:00Z",
                    end: "2026-03-01T00:00:00Z", after: "item-123", max: 50
                )
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            #expect(mam.iq.contains("contact@example.com"))
            #expect(mam.iq.contains("2026-01-01T00:00:00Z"))
            #expect(mam.iq.contains("2026-03-01T00:00:00Z"))
            #expect(mam.iq.contains("<after>item-123</after>"))
            #expect(mam.iq.contains("<max>50</max>"))

            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }

    struct MUCQuery {
        @Test
        func `queryMessages sets to attribute for MUC room archive`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let roomJID = try #require(BareJID.parse("room@conference.example.com"))
            let queryTask = Task {
                try await module.queryMessages(to: roomJID, max: 20)
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            #expect(mam.iq.contains("to=\"room@conference.example.com\""))
            #expect(mam.iq.contains("<max>20</max>"))

            // Response must come from the room JID the request addressed
            await mock.simulateReceive(
                "<iq type='result' id='\(mam.iqID)' from='room@conference.example.com'><fin xmlns='urn:xmpp:mam:2' complete='true'><set xmlns='http://jabber.org/protocol/rsm'><count>0</count></set></fin></iq>"
            )
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }

    struct ResultParsing {
        @Test
        func `Parses result messages with timestamp and stanza-id`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages() }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            await simulateMAMResults(mock: mock, queryID: mam.queryID)
            await sendFinWithRSM(mock: mock, iqID: mam.iqID)

            let result = try await queryTask.value
            #expect(result.messages.count == 2)
            verifyFirstMessage(result.messages[0])
            verifySecondMessage(result.messages[1])
            verifyFin(result.fin)

            await disconnectFast(client)
        }
    }

    struct EmptyArchive {
        @Test
        func `Handles empty archive with no results`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages() }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            await sendEmptyFin(mock: mock, iqID: mam.iqID)

            let result = try await queryTask.value
            #expect(result.messages.isEmpty)
            #expect(result.fin.complete)
            let finCount = result.fin.count
            #expect(finCount == 0)

            await disconnectFast(client)
        }
    }

    struct EventEmission {
        @Test
        func `Emits archivedMessagesLoaded event`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .archivedMessagesLoaded = event { return true }
                    return false
                }
            }

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages() }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            _ = try await queryTask.value

            let events = try await eventsTask.value
            guard case let .archivedMessagesLoaded(messages, fin) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected archivedMessagesLoaded event")
            }
            #expect(messages.isEmpty)
            #expect(fin.complete)

            await disconnectFast(client)
        }
    }

    struct RSMLastPage {
        @Test
        func `queryMessages with lastPage before produces empty before element`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.queryMessages(MAMModule.Query(before: .lastPage, max: 10))
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            #expect(mam.iq.contains("<before/>"))
            #expect(mam.iq.contains("<max>10</max>"))

            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }

    struct ExtendedFields {
        @Test
        func `queryMessages includes extended form with after-id and before-id`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.queryMessages(MAMModule.Query(
                    max: 20, afterID: "abc-123", beforeID: "xyz-789"
                ))
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            #expect(mam.iq.contains("urn:xmpp:mam:2#extended"))
            #expect(mam.iq.contains("after-id"))
            #expect(mam.iq.contains("abc-123"))
            #expect(mam.iq.contains("before-id"))
            #expect(mam.iq.contains("xyz-789"))

            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }

    struct FlipPage {
        @Test
        func `queryMessages includes flip-page in extended form`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let queryTask = Task {
                try await module.queryMessages(MAMModule.Query(
                    before: .lastPage, max: 10, flipPage: true
                ))
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            #expect(mam.iq.contains("urn:xmpp:mam:2#extended"))
            #expect(mam.iq.contains("flip-page"))
            #expect(mam.iq.contains("<before/>"))

            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }

    struct CombinedForms {
        @Test
        func `queryMessages includes both base filter form and extended form`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("contact@example.com"))
            let queryTask = Task {
                try await module.queryMessages(MAMModule.Query(
                    with: jid, start: "2026-01-01T00:00:00Z", afterID: "abc-123"
                ))
            }

            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            // Base filter form
            #expect(mam.iq.contains("urn:xmpp:mam:2</value>"))
            #expect(mam.iq.contains("contact@example.com"))
            #expect(mam.iq.contains("2026-01-01T00:00:00Z"))
            // Extended form
            #expect(mam.iq.contains("urn:xmpp:mam:2#extended"))
            #expect(mam.iq.contains("after-id"))
            #expect(mam.iq.contains("abc-123"))

            await sendEmptyFin(mock: mock, iqID: mam.iqID)
            let result = try await queryTask.value
            #expect(result.fin.complete)

            await disconnectFast(client)
        }
    }
}

extension MAMModuleTests {
    struct ArchiveSender {
        @Test(arguments: [String?.none, "user@example.com"])
        func `A result from the account's own archive is collected`(sender: String?) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages() }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            await mock.simulateReceive(archiveResult(from: sender, queryID: mam.queryID))
            await sendEmptyFin(mock: mock, iqID: mam.iqID)

            let result = try await queryTask.value
            #expect(result.messages.map(\.messageID) == ["msg-001"])

            await disconnectFast(client)
        }

        /// The last three do not parse as an address, which must not count as no sender at all.
        @Test(arguments: [
            "example.com", "mallory@example.com", "user@example.com/other", "room@conference.example.com",
            "a b@example.com", "@example.com", "user@example.com/"
        ])
        func `A result naming an open query of the account's own archive is dropped when another sender sent it`(sender: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages() }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            await mock.simulateReceive(archiveResult(from: sender, queryID: mam.queryID, id: "forged"))
            // Armed: the same query still collects what its archive sends.
            await mock.simulateReceive(archiveResult(from: "user@example.com", queryID: mam.queryID))
            await sendEmptyFin(mock: mock, iqID: mam.iqID)

            let result = try await queryTask.value
            #expect(result.messages.map(\.messageID) == ["msg-001"])

            await disconnectFast(client)
        }

        /// Of more results than a query asked for, those nearest to where it pages from are kept.
        @Test(arguments: [(false, ["msg-001", "msg-002"]), (true, ["msg-002", "msg-003"])])
        func `Results past the count a query asked for are dropped`(pagesBackward: Bool, kept: [String]) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let queryTask = Task { try await module.queryMessages(MAMModule.Query(before: pagesBackward ? .lastPage : .omitted, max: 2)) }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            for id in ["msg-001", "msg-002", "msg-003"] {
                await mock.simulateReceive(archiveResult(from: "user@example.com", queryID: mam.queryID, id: id))
            }
            await sendEmptyFin(mock: mock, iqID: mam.iqID)

            let result = try await queryTask.value
            #expect(result.messages.map(\.messageID) == kept)

            await disconnectFast(client)
        }

        @Test
        func `A room query collects the room's results and drops everyone else's`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: MAMModule.self))

            await mock.clearSentBytes()
            let roomJID = try #require(BareJID.parse("room@conference.example.com"))
            let queryTask = Task { try await module.queryMessages(to: roomJID, max: 20) }
            await mock.waitForSent(count: 1)

            let mam = try #require(await findMAMIQ(mock: mock))
            for sender in [nil, "user@example.com", "example.com", "room@conference.example.com/nick"] {
                await mock.simulateReceive(archiveResult(from: sender, queryID: mam.queryID, id: "forged"))
            }
            await mock.simulateReceive(archiveResult(from: "room@conference.example.com", queryID: mam.queryID))
            await mock.simulateReceive(
                "<iq type='result' id='\(mam.iqID)' from='room@conference.example.com'><fin xmlns='urn:xmpp:mam:2' complete='true'/></iq>"
            )

            let result = try await queryTask.value
            #expect(result.messages.map(\.messageID) == ["msg-001"])

            await disconnectFast(client)
        }
    }
}

/// One archive result for `queryID`, sent by `sender`, or without a sender.
private func archiveResult(from sender: String?, queryID: String, id: String = "msg-001") -> String {
    "<message\(sender.map { " from='\($0)'" } ?? "")>"
        + "<result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='\(id)'>"
        + "<forwarded xmlns='urn:xmpp:forward:0'>"
        + "<delay xmlns='urn:xmpp:delay' stamp='2026-02-28T10:00:00Z'/>"
        + "<message from='contact@example.com/res' to='user@example.com' type='chat'><body>Archived</body></message>"
        + "</forwarded></result></message>"
}

// MARK: - Result Parsing Helpers

private func simulateMAMResults(mock: MockTransport, queryID: String) async {
    await mock.simulateReceive("""
    <message from='user@example.com'>\
    <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='msg-001'>\
    <forwarded xmlns='urn:xmpp:forward:0'>\
    <delay xmlns='urn:xmpp:delay' stamp='2026-02-28T10:00:00Z'/>\
    <message from='contact@example.com/res' to='user@example.com' type='chat'>\
    <body>First message</body>\
    <stanza-id xmlns='urn:xmpp:sid:0' id='server-id-1' by='example.com'/>\
    </message>\
    </forwarded>\
    </result>\
    </message>
    """)

    await mock.simulateReceive("""
    <message from='user@example.com'>\
    <result xmlns='urn:xmpp:mam:2' queryid='\(queryID)' id='msg-002'>\
    <forwarded xmlns='urn:xmpp:forward:0'>\
    <delay xmlns='urn:xmpp:delay' stamp='2026-02-28T11:00:00Z'/>\
    <message from='user@example.com/ducko' to='contact@example.com' type='chat'>\
    <body>Second message</body>\
    </message>\
    </forwarded>\
    </result>\
    </message>
    """)
}

private func sendFinWithRSM(mock: MockTransport, iqID: String) async {
    await mock.simulateReceive("""
    <iq type='result' id='\(iqID)'>\
    <fin xmlns='urn:xmpp:mam:2' complete='true'>\
    <set xmlns='http://jabber.org/protocol/rsm'>\
    <first>msg-001</first>\
    <last>msg-002</last>\
    <count>2</count>\
    </set>\
    </fin>\
    </iq>
    """)
}

private func verifyFirstMessage(_ message: ArchivedMessage) {
    #expect(message.messageID == "msg-001")
    #expect(message.forwarded.message.body == "First message")
    #expect(message.forwarded.timestamp == "2026-02-28T10:00:00Z")
    #expect(message.serverID == "server-id-1")
}

private func verifySecondMessage(_ message: ArchivedMessage) {
    #expect(message.messageID == "msg-002")
    #expect(message.forwarded.message.body == "Second message")
    #expect(message.serverID == nil)
}

private func verifyFin(_ fin: MAMFin) {
    #expect(fin.complete)
    #expect(fin.first == "msg-001")
    #expect(fin.last == "msg-002")
    #expect(fin.count == 2)
}
