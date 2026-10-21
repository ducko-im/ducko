import DuckoTestSupport
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private let testNode = "urn:xmpp:avatar:metadata"
private let testNode2 = "urn:xmpp:avatar:data"

private func makePEPModule(nodes: [String] = [testNode]) -> PEPModule {
    let module = PEPModule()
    for node in nodes {
        module.registerNotifyInterest(node)
    }
    return module
}

private func makeConnectedClient(mock: MockTransport, pepModule: PEPModule) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(pepModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum PEPModuleTests {
    struct Features {
        @Test
        func `Features include registered notify namespaces`() {
            let module = makePEPModule(nodes: [testNode, testNode2])

            let features = module.features
            #expect(features.contains(XMPPNamespaces.pubsub))
            #expect(features.contains(testNode + "+notify"))
            #expect(features.contains(testNode2 + "+notify"))
        }

        @Test
        func `Features exclude unregistered namespaces`() {
            let module = makePEPModule(nodes: [testNode])

            let features = module.features
            #expect(features.contains(testNode + "+notify"))
            #expect(!features.contains(testNode2 + "+notify"))
        }

        @Test
        func `Unregister removes notify feature`() {
            let module = makePEPModule(nodes: [testNode, testNode2])
            module.unregisterNotifyInterest(testNode2)

            let features = module.features
            #expect(features.contains(testNode + "+notify"))
            #expect(!features.contains(testNode2 + "+notify"))
        }
    }

    struct IncomingNotifications {
        @Test
        func `Incoming PEP notification emits pepItemsPublished`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .pepItemsPublished = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='alice@example.com' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='\(testNode)'>
            <item id='item-1'><metadata xmlns='\(testNode)'/></item>
            </items>
            </event>
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .pepItemsPublished(from, node, items) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected pepItemsPublished event")
            }
            #expect(from.description == "alice@example.com")
            #expect(node == testNode)
            #expect(items.count == 1)
            #expect(items.first?.id == "item-1")
            #expect(items.first?.payload.name == "metadata")

            await disconnectFast(client)
        }

        @Test
        func `Incoming retraction emits pepItemsRetracted`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .pepItemsRetracted = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message from='alice@example.com' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='\(testNode)'>
            <retract id='item-1'/>
            </items>
            </event>
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .pepItemsRetracted(from, node, itemIDs) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected pepItemsRetracted event")
            }
            #expect(from.description == "alice@example.com")
            #expect(node == testNode)
            #expect(itemIDs == ["item-1"])

            await disconnectFast(client)
        }

        @Test
        func `A notification without a sender comes from the account itself`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .pepItemsPublished = event { return true }
                    return false
                }
            }

            await mock.simulateReceive("""
            <message to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='\(testNode)'>
            <item id='item-1'><metadata xmlns='\(testNode)'/></item>
            </items>
            </event>
            </message>
            """)

            let events = try await eventsTask.value
            guard case let .pepItemsPublished(from, _, _) = events.last else {
                throw XMPPClientError.unexpectedStreamState("Expected pepItemsPublished event")
            }
            #expect(from.description == "user@example.com")

            await disconnectFast(client)
        }

        @Test(arguments: ["alice@example.com/phone", "@@"])
        func `A notification from anything but a bare JID is ignored`(sender: String) async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.simulateReceive("""
            <message from='\(sender)' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='\(testNode)'>
            <item id='item-1'><metadata xmlns='\(testNode)'/></item>
            <retract id='item-2'/>
            </items>
            </event>
            </message>
            """)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await disconnectFast(client)
            let events = try await eventsTask.value

            let hasPEP = events.contains { event in
                if case .pepItemsPublished = event { return true }
                if case .pepItemsRetracted = event { return true }
                return false
            }
            #expect(!hasPEP)
        }

        @Test
        func `Unregistered node notification is silently ignored`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule(nodes: [testNode])
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            // Send a notification for an unregistered node
            await mock.simulateReceive("""
            <message from='alice@example.com' to='user@example.com'>
            <event xmlns='http://jabber.org/protocol/pubsub#event'>
            <items node='urn:xmpp:unregistered:0'>
            <item id='item-1'><data xmlns='urn:xmpp:unregistered:0'/></item>
            </items>
            </event>
            </message>
            """)

            // Disconnect triggers .disconnected — collect it to verify no PEP event preceded it
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await disconnectFast(client)
            let events = try await eventsTask.value

            let hasPEP = events.contains { event in
                if case .pepItemsPublished = event { return true }
                if case .pepItemsRetracted = event { return true }
                return false
            }
            #expect(!hasPEP)
        }
    }

    struct PublishRetract {
        @Test
        func `publishItem sends correct IQ structure`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.clearSentBytes()

            let payload = XMLElement(name: "data", namespace: testNode)
            let publishTask = Task {
                try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload)
            }

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
            #expect(sentString.contains("<pubsub xmlns=\"http://jabber.org/protocol/pubsub\"") || sentString.contains("<pubsub xmlns='http://jabber.org/protocol/pubsub'"))
            #expect(sentString.contains("node=\"\(testNode)\"") || sentString.contains("node='\(testNode)'"))
            #expect(sentString.contains("id=\"item-1\"") || sentString.contains("id='item-1'"))

            // Respond to unblock the await
            if let iqID = extractIQID(from: sentString) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await publishTask.value
            await disconnectFast(client)
        }

        @Test
        func `publishItem with options includes publish-options`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.clearSentBytes()

            let payload = XMLElement(name: "data", namespace: testNode)
            let options = [
                DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.pubsub + "#publish-options"]),
                DataFormField(variable: "pubsub#access_model", values: ["open"])
            ]
            let publishTask = Task {
                try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload, options: options)
            }

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
            #expect(sentString.contains("publish-options"))
            #expect(sentString.contains("jabber:x:data"))

            if let iqID = extractIQID(from: sentString) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await publishTask.value
            await disconnectFast(client)
        }

        @Test
        func `retrieveItems parses response correctly`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.clearSentBytes()

            let retrieveTask = Task {
                try await pepModule.retrieveItems(node: testNode)
            }

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
            guard let iqID = extractIQID(from: sentString) else {
                throw XMPPClientError.unexpectedStreamState("No IQ ID found")
            }

            await mock.simulateReceive("""
            <iq type='result' id='\(iqID)'>
            <pubsub xmlns='http://jabber.org/protocol/pubsub'>
            <items node='\(testNode)'>
            <item id='item-1'><metadata xmlns='\(testNode)'>some data</metadata></item>
            <item id='item-2'><metadata xmlns='\(testNode)'>other data</metadata></item>
            </items>
            </pubsub>
            </iq>
            """)

            let items = try await retrieveTask.value
            #expect(items.count == 2)
            #expect(items[0].id == "item-1")
            #expect(items[0].payload.name == "metadata")
            #expect(items[1].id == "item-2")

            await disconnectFast(client)
        }

        @Test(arguments: [false, true])
        func `retractItem sends correct IQ structure`(notify: Bool) async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.clearSentBytes()

            let retractTask = Task {
                try await pepModule.retractItem(node: testNode, itemID: "item-1", notify: notify)
            }

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
            #expect(sentString.contains("<retract"))
            #expect(sentString.contains("node=\"\(testNode)\"") || sentString.contains("node='\(testNode)'"))
            #expect(sentString.contains("id=\"item-1\"") || sentString.contains("id='item-1'"))
            #expect(sentString.contains("notify=\"true\"") == notify)

            if let iqID = extractIQID(from: sentString) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await retractTask.value
            await disconnectFast(client)
        }

        @Test
        func `deleteNode sends correct pubsub#owner IQ structure`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)

            await mock.clearSentBytes()

            let deleteTask = Task {
                try await pepModule.deleteNode(node: testNode)
            }

            await mock.waitForSent(count: 1)

            let sentData = await mock.sentBytes
            let sentString = sentData.map { String(decoding: $0, as: UTF8.self) }.joined()
            #expect(sentString.contains("type=\"set\"") || sentString.contains("type='set'"))
            #expect(sentString.contains(XMPPNamespaces.pubsubOwner))
            #expect(sentString.contains("<delete"))
            #expect(sentString.contains("node=\"\(testNode)\"") || sentString.contains("node='\(testNode)'"))

            if let iqID = extractIQID(from: sentString) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await deleteTask.value
            await disconnectFast(client)
        }
    }
}
