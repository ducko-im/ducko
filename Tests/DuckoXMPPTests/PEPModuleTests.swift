import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
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
        transport: mock, requireTLS: false, allowsPLAIN: true
    )
    await client.register(pepModule)

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

private let stanzasNamespace = "urn:ietf:params:xml:ns:xmpp-stanzas"
private let preconditionNotMet = """
<conflict xmlns='\(stanzasNamespace)'/><precondition-not-met xmlns='http://jabber.org/protocol/pubsub#errors'/>
"""
private let reconfigureOptions = [
    DataFormField.pubsubPublishOptionsHeader,
    DataFormField(variable: "pubsub#access_model", values: ["whitelist"])
]

/// Answers each publish with the next of `publishErrors`, a result once they run out or for `nil`, and each
/// configure with `configureError` or a result.
private func answerPEPRequests(on mock: MockTransport, publishErrors: [String?], configureError: String? = nil) async {
    let publishCount = OSAllocatedUnfairLock(initialState: 0)
    await mock.autoReply { stanza in
        guard let id = extractIQID(from: stanza) else { return nil }
        let error: String?
        if stanza.contains("<publish ") {
            error = publishCount.withLock { count in
                defer { count += 1 }
                return count < publishErrors.count ? publishErrors[count] : nil
            }
        } else if stanza.contains("<configure ") {
            error = configureError
        } else {
            return nil
        }
        guard let error else { return "<iq type='result' id='\(id)'/>" }
        return "<iq type='error' id='\(id)'><error type='cancel'>\(error)</error></iq>"
    }
}

private func sentIQs(_ mock: MockTransport) async -> [String] {
    await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }.filter { $0.hasPrefix("<iq") }
}

// MARK: - Tests

enum PEPModuleTests {
    struct Features {
        @Test
        func `Features include registered notify namespaces`() {
            let module = makePEPModule(nodes: [testNode, testNode2])

            let features = module.features
            #expect(features.contains(testNode + "+notify"))
            #expect(features.contains(testNode2 + "+notify"))
        }

        @Test
        func `Does not advertise itself as a pubsub service`() {
            #expect(!makePEPModule(nodes: [testNode]).features.contains(XMPPNamespaces.pubsub))
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

    struct NodeReconfiguration {
        @Test
        func `A publish refused for its options reconfigures the node and publishes again`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)
            await mock.clearSentBytes()
            await answerPEPRequests(on: mock, publishErrors: [preconditionNotMet])

            let payload = XMLElement(name: "data", namespace: testNode)
            try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload, options: reconfigureOptions)

            let sent = await sentIQs(mock)
            try #require(sent.count == 3)
            #expect(sent[0].contains("<publish "))
            #expect(sent[1].contains("<pubsub xmlns=\"\(XMPPNamespaces.pubsubOwner)\""))
            #expect(sent[1].contains("<configure node=\"\(testNode)\""))
            #expect(sent[1].contains("<value>\(XMPPNamespaces.pubsubNodeConfig)</value>"))
            #expect(sent[1].contains("var=\"pubsub#access_model\""))
            #expect(sent[1].contains("<value>whitelist</value>"))
            #expect(!sent[1].contains(XMPPNamespaces.pubsubPublishOptions))
            #expect(sent[2].contains("<publish "))
            #expect(sent[2].contains("<publish-options>"))

            await disconnectFast(client)
        }

        @Test(arguments: [
            "<conflict xmlns='\(stanzasNamespace)'/>",
            "<not-acceptable xmlns='\(stanzasNamespace)'/><precondition-not-met xmlns='http://jabber.org/protocol/pubsub#errors'/>"
        ])
        func `Any other publish error reaches the caller without a reconfigure`(error: String) async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)
            await mock.clearSentBytes()
            await answerPEPRequests(on: mock, publishErrors: [error])

            let payload = XMLElement(name: "data", namespace: testNode)
            await #expect(throws: XMPPStanzaError.self) {
                try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload, options: reconfigureOptions)
            }

            #expect(await sentIQs(mock).count == 1)
            await disconnectFast(client)
        }

        @Test
        func `A failed reconfigure reaches the caller without a second publish`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)
            await mock.clearSentBytes()
            await answerPEPRequests(
                on: mock, publishErrors: [preconditionNotMet], configureError: "<forbidden xmlns='\(stanzasNamespace)'/>"
            )

            let payload = XMLElement(name: "data", namespace: testNode)
            let error = await #expect(throws: XMPPStanzaError.self) {
                try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload, options: reconfigureOptions)
            }

            #expect(error?.condition == .forbidden)
            let sent = await sentIQs(mock)
            #expect(sent.count == 2)
            #expect(sent.last?.contains("<configure ") == true)
            await disconnectFast(client)
        }

        @Test
        func `A second refusal after the reconfigure reaches the caller`() async throws {
            let mock = MockTransport()
            let pepModule = makePEPModule()
            let client = try await makeConnectedClient(mock: mock, pepModule: pepModule)
            await mock.clearSentBytes()
            await answerPEPRequests(on: mock, publishErrors: [preconditionNotMet, preconditionNotMet, preconditionNotMet])

            let payload = XMLElement(name: "data", namespace: testNode)
            let error = await #expect(throws: XMPPStanzaError.self) {
                try await pepModule.publishItem(node: testNode, itemID: "item-1", payload: payload, options: reconfigureOptions)
            }

            #expect(error?.condition == .conflict)
            let sent = await sentIQs(mock)
            #expect(sent.count == 3)
            #expect(sent.count { $0.contains("<configure ") } == 1)
            await disconnectFast(client)
        }
    }
}
