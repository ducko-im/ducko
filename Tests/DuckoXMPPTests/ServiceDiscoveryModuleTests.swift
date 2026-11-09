import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
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
    await mock.answerDiscoInfo(of: "user@example.com")

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// The account's disco#info answer, listing the archive feature.
private func accountInfoResult(id: String) -> String {
    """
    <iq type='result' id='\(id)' from='user@example.com'>\
    <query xmlns='\(XMPPNamespaces.discoInfo)'><feature var='\(XMPPNamespaces.mam)'/></query>\
    </iq>
    """
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

    struct AccountInfo {
        /// Starts signing in with `disco` and initial presence, and returns once the bind is answered.
        private static func startSignIn(mock: MockTransport, disco: ServiceDiscoveryModule) async -> (XMPPClient, Task<Void, any Error>) {
            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false, allowsPLAIN: true
            )
            await client.register(disco)
            await client.register(PresenceModule())
            let signIn = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            return (client, signIn)
        }

        private static func awaitAccountQuery(on mock: MockTransport) async throws -> String {
            try await awaitOutgoingIQ(on: mock, type: .get, namespace: XMPPNamespaces.discoInfo) {
                $0.contains("to=\"user@example.com\"")
            }.id
        }

        @Test
        func `The account's info is stored before initial presence goes out`() async throws {
            let mock = MockTransport()
            let disco = ServiceDiscoveryModule()
            let (client, signIn) = await Self.startSignIn(mock: mock, disco: disco)

            let queryID = try await Self.awaitAccountQuery(on: mock)
            let sentBeforeAnswer = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sentBeforeAnswer.contains { $0.hasPrefix("<presence") })
            await mock.simulateReceive(accountInfoResult(id: queryID))

            #expect(await mock.waitForSent { $0.hasPrefix("<presence") } != nil)
            #expect(disco.knownAccountInfo?.features.contains(XMPPNamespaces.mam) == true)
            try await signIn.value

            await disconnectFast(client)
        }

        @Test
        func `An account answering late holds sign-in for at most five seconds, and its answer is still stored`() async throws {
            let mock = MockTransport()
            let disco = ServiceDiscoveryModule()
            let started = ContinuousClock.now
            let (client, signIn) = await Self.startSignIn(mock: mock, disco: disco)
            let queryID = try await Self.awaitAccountQuery(on: mock)

            try await signIn.value
            #expect(ContinuousClock.now - started < .seconds(7))
            #expect(disco.knownAccountInfo == nil)

            await mock.simulateReceive(accountInfoResult(id: queryID))
            #expect(await disco.accountInfo()?.features.contains(XMPPNamespaces.mam) == true)

            await disconnectFast(client)
        }

        @Test(arguments: [true, false])
        func `The account's info carried for a resume is kept only when the stream resumes`(resumed: Bool) {
            let carried = ServiceDiscoveryModule.InfoResult(identities: [], features: [XMPPNamespaces.mam])
            let module = ServiceDiscoveryModule(resuming: carried)
            #expect(module.knownAccountInfo?.features == [XMPPNamespaces.mam])

            module.handleSessionEstablished(resumed: resumed)

            #expect((module.knownAccountInfo != nil) == resumed)
        }

        @Test(arguments: [false, true])
        func `A resume asks the account for its info only when it carried none, without waiting for the answer`(carriesAccountInfo: Bool) async throws {
            let requests = OSAllocatedUnfairLock(initialState: 0)
            let answered = AsyncSemaphore()
            let carried = ServiceDiscoveryModule.InfoResult(identities: [], features: [XMPPNamespaces.stanzaID])
            let module = ServiceDiscoveryModule(resuming: carriesAccountInfo ? carried : nil)
            module.setUp(makeStubModuleContext(sendIQ: { _, _ in
                requests.withLock { $0 += 1 }
                await answered.wait()
                return discoInfoQuery(features: [XMPPNamespaces.mam])
            }))
            module.handleSessionEstablished(resumed: true)

            let resumed = try await boundedOutcome { try await module.handleResume() }
            #expect(resumed != nil)
            await answered.signal()

            if carriesAccountInfo {
                // A query the resume started would have been sent by now.
                try await Task.sleep(for: .milliseconds(200))
                #expect(requests.withLock { $0 } == 0)
                #expect(module.knownAccountInfo?.features == carried.features)
            } else {
                try await eventually { module.knownAccountInfo?.features == [XMPPNamespaces.mam] }
            }
        }

        @Test
        func `Asking for the account's info before sign-in reaches the module starts the query that sign-in then shares`() async throws {
            let requests = OSAllocatedUnfairLock(initialState: [String]())
            let requested = AsyncSemaphore()
            let answered = AsyncSemaphore()
            let module = ServiceDiscoveryModule()
            module.setUp(makeStubModuleContext(sendIQ: { iq, _ in
                requests.withLock { $0.append(iq.to?.description ?? "") }
                await requested.signal()
                await answered.wait()
                return discoInfoQuery(features: [XMPPNamespaces.mam])
            }))

            let early = Task { await module.accountInfo() }
            await requested.wait()
            let connect = Task { try await module.handleConnect() }
            await answered.signal()
            try await connect.value

            #expect(await early.value?.features == [XMPPNamespaces.mam])
            #expect(requests.withLock { $0 } == ["user@example.com"])
        }
    }
}
