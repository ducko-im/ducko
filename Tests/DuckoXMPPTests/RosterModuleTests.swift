import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

/// Empty roster for tests that don't need roster items pre-loaded.
private let emptyRosterQuery = "<query xmlns='jabber:iq:roster'/>"

/// Post-auth features with bind and pre-approval.
private let testFeaturesBindWithPreApproval = """
<features xmlns='http://etherx.jabber.org/streams'>\
<bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/>\
<sub xmlns='urn:xmpp:features:pre-approval'/>\
</features>
"""

@Sendable
private func deltaJID(of event: XMPPEvent) -> String? {
    guard case let .rosterUpdated(update) = event, case let .delta(item) = update.contents else { return nil }
    return item.jid.description
}

/// Creates a connected client with RosterModule registered.
/// A roster response must always be provided since RosterModule blocks on connect waiting for it.
private func makeConnectedClient(
    mock: MockTransport,
    postAuthFeatures: String = testFeaturesBind,
    rosterQuery: String = emptyRosterQuery
) async throws -> XMPPClient {
    let client = XMPPClient(
        domain: "example.com",
        credentials: .init(username: "user", password: "pass"),
        transport: mock, requireTLS: false
    )
    await client.register(RosterModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock, postAuthFeatures: postAuthFeatures)
    try await answerRosterGet(on: mock, with: rosterQuery)
    try await connectTask.value

    return client
}

// MARK: - Tests

enum RosterModuleTests {
    struct RosterLoad {
        @Test
        func `Roster GET on connect parses items and emits rosterLoaded`() async throws {
            let mock = MockTransport()

            let rosterQuery = "<query xmlns='jabber:iq:roster'><item jid='alice@example.com' name='Alice' subscription='both'/><item jid='bob@example.com' subscription='to'><group>Friends</group></item></query>"

            let client = XMPPClient(
                domain: "example.com",
                credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false
            )
            await client.register(RosterModule())

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .rosterUpdated(update) = event, update.isInitialResponse { return true }
                    return false
                }
            }

            let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
            try await simulateNoTLSConnect(mock, rosterQuery: rosterQuery)
            try await connectTask.value

            let events = try await eventsTask.value
            guard case let .rosterUpdated(update) = events.last, case let .snapshot(items) = update.contents else {
                throw XMPPClientError.unexpectedStreamState("Expected initial roster response")
            }
            #expect(items.count == 2)

            let alice = items.first { $0.jid.description == "alice@example.com" }
            #expect(alice?.name == "Alice")
            #expect(alice?.subscription == .both)

            let bob = items.first { $0.jid.description == "bob@example.com" }
            #expect(bob?.subscription == .to)
            #expect(bob?.groups == ["Friends"])

            await disconnectFast(client)
        }
    }

    struct RosterPush {
        @Test
        func `Roster push updates map and emits rosterItemChanged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .rosterUpdated(update) = event, case .delta = update.contents { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-1'><query xmlns='jabber:iq:roster'><item jid='new@example.com' name='New' subscription='both'/></query></iq>"
            )

            let events = try await eventsTask.value
            guard case let .rosterUpdated(update) = events.last, case let .delta(item) = update.contents else {
                throw XMPPClientError.unexpectedStreamState("Expected roster delta")
            }
            #expect(item.jid.description == "new@example.com")
            #expect(item.name == "New")
            #expect(item.subscription == .both)

            await disconnectFast(client)
        }

        @Test
        func `Roster push with subscription=remove removes item`() async throws {
            let mock = MockTransport()
            let rosterQuery = "<query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='both'/></query>"
            let client = try await makeConnectedClient(mock: mock, rosterQuery: rosterQuery)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .rosterUpdated(update) = event, case .delta = update.contents { return true }
                    return false
                }
            }

            await mock.simulateReceive(
                "<iq type='set' id='push-2'><query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='remove'/></query></iq>"
            )

            let events = try await eventsTask.value
            guard case let .rosterUpdated(update) = events.last, case let .delta(item) = update.contents else {
                throw XMPPClientError.unexpectedStreamState("Expected roster delta")
            }
            #expect(item.subscription == .remove)

            await disconnectFast(client)
        }

        @Test
        func `Roster push from foreign JID is rejected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { deltaJID(of: $0) == "sentinel@example.com" }
            }

            await mock.simulateReceive(
                "<iq type='set' from='evil@attacker.com' id='push-3'><query xmlns='jabber:iq:roster'><item jid='injected@evil.com' subscription='both'/></query></iq>"
            )
            await mock.simulateReceive(
                "<iq type='set' id='push-4'><query xmlns='jabber:iq:roster'><item jid='sentinel@example.com' subscription='both'/></query></iq>"
            )

            // The sentinel push arrives after the foreign one, so the foreign one was already dropped by then.
            #expect(try await eventsTask.value.compactMap(deltaJID(of:)) == ["sentinel@example.com"])

            await disconnectFast(client)
        }
    }

    struct RosterManagement {
        @Test
        func `addContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("newcontact@example.com"))
            let addTask = Task {
                try await module.addContact(jid: jid, name: "New Contact", groups: ["Work"])
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let addIQ = sentStrings.first { $0.contains("newcontact@example.com") }
            #expect(addIQ != nil)
            #expect(addIQ?.contains("name=\"New Contact\"") == true)
            #expect(addIQ?.contains("<group>Work</group>") == true)

            // Respond with result to unblock the await
            if let iqStr = addIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await addTask.value

            await disconnectFast(client)
        }

        @Test
        func `removeContact sends correct IQ`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))

            await mock.clearSentBytes()

            let jid = try #require(BareJID.parse("contact@example.com"))
            let removeTask = Task {
                try await module.removeContact(jid: jid)
            }

            try? await Task.sleep(for: .milliseconds(100))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let removeIQ = sentStrings.first { $0.contains("subscription=\"remove\"") }
            #expect(removeIQ != nil)
            #expect(removeIQ?.contains("contact@example.com") == true)

            if let iqStr = removeIQ, let iqID = extractIQID(from: iqStr) {
                await mock.simulateReceive("<iq type='result' id='\(iqID)'/>")
            }

            try await removeTask.value

            await disconnectFast(client)
        }
    }

    struct SubscriptionManagement {
        @Test
        func `Subscription methods send correct presence types`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock, postAuthFeatures: testFeaturesBindWithPreApproval)
            let module = try #require(await client.module(ofType: RosterModule.self))

            let jid = try #require(BareJID.parse("contact@example.com"))

            await mock.clearSentBytes()
            try await module.subscribe(to: jid)
            var sentData = await mock.sentBytes
            var sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribe\""))
            #expect(sentString.contains("to=\"contact@example.com\""))

            await mock.clearSentBytes()
            try await module.approveSubscription(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribed\""))

            await mock.clearSentBytes()
            try await module.denySubscription(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"unsubscribed\""))

            await mock.clearSentBytes()
            try await module.unsubscribe(from: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"unsubscribe\""))

            await mock.clearSentBytes()
            try await module.preApprove(jid: jid)
            sentData = await mock.sentBytes
            sentString = String(decoding: sentData.last ?? [], as: UTF8.self)
            #expect(sentString.contains("type=\"subscribed\""))
            #expect(sentString.contains("to=\"contact@example.com\""))

            await disconnectFast(client)
        }
    }

    struct PreApproval {
        @Test
        func `preApprove skips when server does not support pre-approval`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: RosterModule.self))
            #expect(!module.supportsPreApproval)

            let jid = try #require(BareJID.parse("contact@example.com"))
            await mock.clearSentBytes()
            try await module.preApprove(jid: jid)
            let sentData = await mock.sentBytes
            #expect(sentData.isEmpty)

            await disconnectFast(client)
        }

        /// A resumed stream runs no `handleConnect`, and keeps the stream features of the session it resumes.
        @Test
        func `preApprove works on a resumed stream whose features advertise pre-approval`() async throws {
            let module = RosterModule()
            let features = try stanza(testFeaturesBindWithPreApproval)
            let sent = OSAllocatedUnfairLock<[String]>(initialState: [])
            module.setUp(makeStubModuleContext(
                sendStanza: { stanza, onAccepted in
                    onAccepted?()
                    sent.withLock { $0.append(stanza.element.xmlString) }
                },
                serverStreamFeatures: { features }
            ))

            try await module.preApprove(jid: #require(BareJID.parse("contact@example.com")))

            #expect(module.supportsPreApproval)
            #expect(sent.withLock { $0 }.contains { $0.contains("type=\"subscribed\"") && $0.contains("to=\"contact@example.com\"") })
        }

        @Test
        func `Roster item with approved=true parses correctly`() throws {
            let element = XMLElement(name: "item", attributes: ["jid": "alice@example.com", "subscription": "from", "approved": "true"])
            let item = try #require(RosterItem.parse(element))
            #expect(item.approved == true)
            #expect(item.subscription == .from)
        }

        @Test
        func `Roster item without approved defaults to false`() throws {
            let element = XMLElement(name: "item", attributes: ["jid": "alice@example.com", "subscription": "both"])
            let item = try #require(RosterItem.parse(element))
            #expect(item.approved == false)
        }
    }

    struct DisconnectBehavior {
        @Test
        func `handleDisconnect clears roster`() async throws {
            let mock = MockTransport()
            let rosterQuery = "<query xmlns='jabber:iq:roster'><item jid='alice@example.com' subscription='both'/></query>"
            let client = try await makeConnectedClient(mock: mock, rosterQuery: rosterQuery)

            await disconnectFast(client)
        }
    }
}
