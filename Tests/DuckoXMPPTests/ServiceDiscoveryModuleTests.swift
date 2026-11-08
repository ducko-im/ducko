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
    await client.register(ServiceDiscoveryModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum ServiceDiscoveryModuleTests {
    struct DiscoInfoResponse {
        @Test
        func `Responds to disco#info GET with identity and features`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let response = await awaitSentResponse(
                on: mock,
                afterReceiving: "<iq type='get' from='other@example.com/res' id='disco-1'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
                matching: { $0.contains("disco-1") && $0.contains("result") }
            )
            #expect(response != nil)
            #expect(response?.contains("category=\"client\"") == true)
            #expect(response?.contains("type=\"pc\"") == true)
            #expect(response?.contains("name=\"Ducko\"") == true)

            await disconnectFast(client)
        }

        @Test
        func `Response echoes queried node attribute`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // XEP-0115 §6.2 / XEP-0390 §4.2: strict-match caps verifiers
            // (e.g. Prosody mod_caps) expect the response to echo the exact
            // node attribute from the request.
            let capsNode = "http://jabber.org/protocol/caps#abc123"
            let response = await awaitSentResponse(
                on: mock,
                afterReceiving: "<iq type='get' from='other@example.com/res' id='disco-2'><query xmlns='http://jabber.org/protocol/disco#info' node='\(capsNode)'/></iq>",
                matching: { $0.contains("disco-2") && $0.contains("result") }
            )
            #expect(response != nil)
            #expect(response?.contains("node=\"\(capsNode)\"") == true)

            await disconnectFast(client)
        }

        @Test
        func `Response omits node attribute when query has none`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Negative case for the XEP-0115 echo: adding a node attribute
            // asymmetrically would also break strict-match verifiers.
            let response = await awaitSentResponse(
                on: mock,
                afterReceiving: "<iq type='get' from='other@example.com/res' id='disco-3'><query xmlns='http://jabber.org/protocol/disco#info'/></iq>",
                matching: { $0.contains("disco-3") && $0.contains("result") }
            )
            #expect(response != nil)
            #expect(response?.contains("node=") == false)

            await disconnectFast(client)
        }
    }

    struct DiscoInfoQuery {
        @Test
        func `queryInfo parses identities and features`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ServiceDiscoveryModule.self))

            let result = try await withIQOperation(client: client, operation: {
                try await module.queryInfo(for: .bare(BareJID.parse("server.example.com")!))
            }, respond: {
                let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#info") {
                    $0.contains("to=\"server.example.com\"")
                }.id
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='server.example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#info'>\
                <identity category='server' type='im' name='Example Server'/>\
                <feature var='http://jabber.org/protocol/disco#info'/>\
                <feature var='http://jabber.org/protocol/disco#items'/>\
                </query>\
                </iq>
                """)
            })
            #expect(result.identities.count == 1)
            #expect(result.identities[0].category == "server")
            #expect(result.identities[0].type == "im")
            #expect(result.identities[0].name == "Example Server")
            #expect(result.features.count == 2)
            #expect(result.features.contains("http://jabber.org/protocol/disco#info"))
            #expect(result.features.contains("http://jabber.org/protocol/disco#items"))

            await disconnectFast(client)
        }
    }

    struct NotConnected {
        @Test
        func `queryInfo on an unregistered module throws notConnected`() async throws {
            let module = ServiceDiscoveryModule()
            let error = await #expect(throws: XMPPClientError.self) {
                try await module.queryInfo(for: .bare(#require(BareJID.parse("server.example.com"))))
            }
            guard case .notConnected = error else {
                Issue.record("Expected notConnected, got \(String(describing: error))")
                return
            }
        }

        @Test
        func `queryItems on an unregistered module throws notConnected`() async throws {
            let module = ServiceDiscoveryModule()
            let error = await #expect(throws: XMPPClientError.self) {
                try await module.queryItems(for: .bare(#require(BareJID.parse("example.com"))))
            }
            guard case .notConnected = error else {
                Issue.record("Expected notConnected, got \(String(describing: error))")
                return
            }
        }
    }

    struct DiscoItemsQuery {
        @Test
        func `queryItems parses items`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ServiceDiscoveryModule.self))

            let result = try await withIQOperation(client: client, operation: {
                try await module.queryItems(for: .bare(BareJID.parse("example.com")!))
            }, respond: {
                let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#items") {
                    $0.contains("to=\"example.com\"")
                }.id
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#items'>\
                <item jid='conference.example.com' name='Chat Rooms'/>\
                <item jid='pubsub.example.com' name='PubSub Service'/>\
                <item jid='alice@example.com' node='urn:xmpp:omemo:2:bundles:42'/>\
                <item jid='bob@example.com'/>\
                </query>\
                </iq>
                """)
            })
            #expect(result.count == 4)
            #expect(result[0].jid.description == "conference.example.com")
            #expect(result[0].name == "Chat Rooms")
            #expect(result[0].node == nil)
            #expect(result[1].jid.description == "pubsub.example.com")
            #expect(result[1].name == "PubSub Service")
            #expect(result[1].node == nil)
            #expect(result[2].jid.description == "alice@example.com")
            #expect(result[2].name == nil)
            #expect(result[2].node == "urn:xmpp:omemo:2:bundles:42")
            #expect(result[3].jid.description == "bob@example.com")
            #expect(result[3].name == nil)
            #expect(result[3].node == nil)

            await disconnectFast(client)
        }

        @Test
        func `queryItems handles empty result`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: ServiceDiscoveryModule.self))

            let result = try await withIQOperation(client: client, operation: {
                try await module.queryItems(for: .bare(BareJID.parse("example.com")!))
            }, respond: {
                let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "http://jabber.org/protocol/disco#items") {
                    $0.contains("to=\"example.com\"")
                }.id
                await mock.simulateReceive("""
                <iq type='result' id='\(iqID)' from='example.com'>\
                <query xmlns='http://jabber.org/protocol/disco#items'/>\
                </iq>
                """)
            })
            #expect(result.isEmpty)

            await disconnectFast(client)
        }
    }
}
