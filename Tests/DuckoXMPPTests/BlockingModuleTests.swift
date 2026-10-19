import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Empty blocklist response for tests that don't need pre-loaded blocked JIDs.
private let emptyBlocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'/></iq>"

/// Creates a connected client with BlockingModule registered.
private func makeConnectedClient(mock: MockTransport, blocklistResponse: String = emptyBlocklistResponse) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(BlockingModule())

    try await withIQOperation(client: client, operation: {
        try await client.connect(host: "example.com", port: 5222)
    }, respond: {
        await simulateNoTLSConnect(mock)
        let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "urn:xmpp:blocking") {
            $0.contains("<blocklist")
        }.id
        await mock.simulateReceive(blocklistResponse.replacingOccurrences(of: "{requestID}", with: iqID))
    })

    return client
}

// MARK: - Tests

enum BlockingModuleTests {
    struct BlockListLoad {
        @Test
        func `Blocklist GET on connect parses JIDs and emits blockListLoaded`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spam@example.com'/><item jid='troll@example.com'/></blocklist></iq>"

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(BlockingModule())

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .blockListLoaded = event { return true }
                    return false
                }
            }

            defer { eventsTask.cancel() }
            try await withIQOperation(client: client, operation: {
                try await client.connect(host: "example.com", port: 5222)
            }, respond: {
                await simulateNoTLSConnect(mock)
                let iqID = try await awaitOutgoingIQ(on: mock, type: .get, namespace: "urn:xmpp:blocking") {
                    $0.contains("<blocklist")
                }.id
                await mock.simulateReceive(blocklistResponse.replacingOccurrences(of: "{requestID}", with: iqID))
            })

            let events = try await eventsTask.value
            guard case let .blockListLoaded(jids) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected blockListLoaded event")
            }
            #expect(jids.count == 2)

            let module = try #require(await client.module(ofType: BlockingModule.self))
            #expect(module.blockedJIDs.count == 2)

            await disconnectFast(client)
        }
    }

    struct BlockUnblock {
        @Test
        func `blockContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("spam@example.com"))
            try await withIQOperation(client: client, operation: {
                try await module.blockContact(jid: jid)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:blocking") {
                    $0.contains("<block ") && $0.contains("spam@example.com")
                }
                #expect(request.xml.contains("<block xmlns=\"urn:xmpp:blocking\""))
                await mock.simulateReceive("<iq type='result' id='\(request.id)'/>")
            })
            await disconnectFast(client)
        }

        @Test
        func `unblockContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("spam@example.com"))
            try await withIQOperation(client: client, operation: {
                try await module.unblockContact(jid: jid)
            }, respond: {
                let request = try await awaitOutgoingIQ(on: mock, type: .set, namespace: "urn:xmpp:blocking") {
                    $0.contains("<unblock ") && $0.contains("spam@example.com")
                }
                #expect(request.xml.contains("<unblock xmlns=\"urn:xmpp:blocking\""))
                await mock.simulateReceive("<iq type='result' id='\(request.id)'/>")
            })
            await disconnectFast(client)
        }
    }

    struct PushHandling {
        @Test
        func `Block push IQ updates blocked set and emits contactBlocked`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactBlocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-1'><block xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></block></iq>"
            )

            let events = try await eventsTask.value
            guard case let .contactBlocked(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected contactBlocked event")
            }
            #expect(jid.description == "spammer@example.com")
            #expect(module.blockedJIDs.contains(jid))

            await disconnectFast(client)
        }

        @Test
        func `Unblock push IQ updates blocked set and emits contactUnblocked`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></blocklist></iq>"
            let client = try await makeConnectedClient(mock: mock, blocklistResponse: blocklistResponse)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            #expect(module.blockedJIDs.count == 1)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactUnblocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-2'><unblock xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></unblock></iq>"
            )

            let events = try await eventsTask.value
            guard case let .contactUnblocked(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected contactUnblocked event")
            }
            #expect(jid.description == "spammer@example.com")
            #expect(!module.blockedJIDs.contains(jid))

            await disconnectFast(client)
        }

        @Test
        func `Block push from own bare JID is accepted`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactBlocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' from='user@example.com' id='push-3'><block xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></block></iq>"
            )

            _ = try await eventsTask.value
            #expect(module.blockedJIDs.map(\.description) == ["spammer@example.com"])

            await disconnectFast(client)
        }

        @Test(arguments: ["evil@attacker.com", "user@example.com/other", "@example.com"])
        func `Block push from any sender but own bare JID is rejected`(sender: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .contactBlocked = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' from='\(sender)' id='push-3'><block xmlns='urn:xmpp:blocking'><item jid='injected@evil.com'/></block></iq>"
            )
            await mock.simulateReceive(
                "<iq type='set' id='push-4'><block xmlns='urn:xmpp:blocking'><item jid='spammer@example.com'/></block></iq>"
            )

            let events = try await eventsTask.value
            guard case let .contactBlocked(jid) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected contactBlocked event")
            }
            #expect(jid.description == "spammer@example.com")
            #expect(module.blockedJIDs == [jid])

            await disconnectFast(client)
        }

        /// Another client can unblock an address with a resource, which this module does not track. That is not an
        /// unblock of everyone.
        @Test
        func `An unblock naming only full JIDs leaves the block list alone`() throws {
            let module = BlockingModule()
            let events = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
            module.setUp(makeStubModuleContext(emitEvent: { event in events.withLock { $0.append(event) } }))

            _ = try module.handleIQ(XMPPIQ(element: stanza(
                "<iq type='set' id='push-1'><unblock xmlns='urn:xmpp:blocking'><item jid='spam@example.com/bot'/></unblock></iq>"
            )))

            let emitted = events.withLock { $0 }
            #expect(emitted.isEmpty)
        }
    }

    struct StreamResume {
        /// A module built for a resumed stream never loaded the list, so it cannot name the contacts an empty unblock
        /// frees.
        @Test
        func `An empty unblock on a resumed stream announces an empty block list`() throws {
            let module = BlockingModule()
            let events = OSAllocatedUnfairLock<[XMPPEvent]>(initialState: [])
            module.setUp(makeStubModuleContext(emitEvent: { event in events.withLock { $0.append(event) } }))

            _ = try module.handleIQ(XMPPIQ(element: stanza("<iq type='set' id='push-1'><unblock xmlns='urn:xmpp:blocking'/></iq>")))

            let emitted = events.withLock { $0 }
            guard emitted.count == 1, case let .blockListLoaded(jids) = emitted[0] else {
                Issue.record("Expected one blockListLoaded event, got \(emitted)")
                return
            }
            #expect(jids.isEmpty)
        }
    }

    struct DisconnectBehavior {
        @Test
        func `handleDisconnect clears blocked JIDs`() async throws {
            let mock = MockTransport()

            let blocklistResponse = "<iq type='result' id='{requestID}'><blocklist xmlns='urn:xmpp:blocking'><item jid='spam@example.com'/></blocklist></iq>"
            let client = try await makeConnectedClient(mock: mock, blocklistResponse: blocklistResponse)
            let module = try #require(await client.module(ofType: BlockingModule.self))

            #expect(!module.blockedJIDs.isEmpty)

            await disconnectFast(client)

            #expect(module.blockedJIDs.isEmpty)
        }
    }
}
