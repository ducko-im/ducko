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
    await client.register(JingleModule())

    let connectTask = Task { try await client.connect(host: "example.com", port: 5222) }
    await simulateNoTLSConnect(mock)
    try await connectTask.value

    return client
}

/// Builds a session-initiate IQ XML string for testing.
private func sessionInitiateXML(
    id: String = "jingle-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    fileName: String = "test.txt",
    fileSize: Int64 = 1024,
    mediaType: String? = "text/plain",
    senders: String? = nil,
    rangeXML: String = ""
) -> String {
    var mediaTypeXML = ""
    if let mediaType {
        mediaTypeXML = "<media-type>\(mediaType)</media-type>"
    }
    let sendersAttr = senders.map { " senders='\($0)'" } ?? ""
    return """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'\(sendersAttr)>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>\(fileName)</name>\
    <size>\(fileSize)</size>\
    \(mediaTypeXML)\
    \(rangeXML)\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a session-info checksum IQ XML string for testing.
private func sessionInfoChecksumXML(
    id: String = "jingle-info-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    contentName: String = "a-file-offer",
    algo: String = "sha-256",
    hash: String = "dGVzdA=="
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-info' sid='\(sid)'>\
    <checksum xmlns='urn:xmpp:jingle:apps:file-transfer:5' name='\(contentName)'>\
    <file>\
    <hash xmlns='urn:xmpp:hashes:2' algo='\(algo)'>\(hash)</hash>\
    </file>\
    </checksum>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-replace IQ with IBB transport for testing.
private func transportReplaceXML(
    id: String = "tr-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback",
    blockSize: Int = 4096
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-replace' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:ibb:1' sid='\(ibbSID)' block-size='\(blockSize)'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a session-terminate IQ XML string for testing.
private func sessionTerminateXML(
    id: String = "jingle-2",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    reason: String = "success"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='\(sid)'>\
    <reason><\(reason)/></reason>\
    </jingle>\
    </iq>
    """
}

// MARK: - Tests

enum JingleModuleTests { // swiftlint:disable:this type_body_length
    struct SessionInitiateHandling {
        @Test
        func `Emits jingleFileTransferReceived on session-initiate`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            guard case let .jingleFileTransferReceived(offer) = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await disconnectFast(client)
                return
            }
            #expect(offer.sid == "sid-123")
            #expect(offer.fileName == "test.txt")
            #expect(offer.fileSize == 1024)
            #expect(offer.mediaType == "text/plain")
            #expect(offer.from.description == "peer@example.com/res")

            await disconnectFast(client)
        }
    }

    struct TransportWaitAfterTerminate {
        @Test
        func `Waiting for the transport of an ended session fails instead of hanging`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            // The failure event is emitted after the session is removed, so awaiting it orders the wait after the terminate.
            let terminated = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(sessionTerminateXML(reason: "cancel"))
            _ = try await terminated.value

            let outcome = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-123") }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)
            await disconnectFast(client)
        }
    }

    struct AbandonedTransport {
        /// Delivers an offer and the peer's removal of its only content, returning once the abandoned transfer's failure
        /// was reported.
        private static func receiveAbandonedOffer(client: XMPPClient, mock: MockTransport) async throws {
            let abandoned = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(
                "<iq type='set' id='content-remove-1' from='peer@example.com/res'><jingle xmlns='urn:xmpp:jingle:1' action='content-remove' sid='sid-123'><content creator='initiator' name='a-file-offer'/></jingle></iq>"
            )
            _ = try await abandoned.value
        }

        @Test
        func `A terminate for an abandoned transport reports no second failure`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            try await Self.receiveAbandonedOffer(client: client, mock: mock)

            // The offer that follows the terminate marks the point by which a failure would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionTerminateXML(reason: "cancel"))
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-2", sid: "sid-next"))

            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A transport-replace after the transport was abandoned does not revive it`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await Self.receiveAbandonedOffer(client: client, mock: mock)

            // The offer that follows the transport-replace marks the point by which the replace was handled.
            let handled = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(transportReplaceXML())
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-next", sid: "sid-next"))
            _ = try await handled.value

            let outcome = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-123") }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)
            await disconnectFast(client)
        }
    }

    struct RepeatedAccept {
        private static func receiveOffer(client: XMPPClient, mock: MockTransport) async throws {
            let offered = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            _ = try await offered.value
        }

        @Test
        func `Accepting a session that does not exist fails with session not found`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await module.acceptFileTransfer(sid: "unknown-sid")
            }
            await disconnectFast(client)
        }

        @Test
        func `A repeated accept is rejected without sending a second session-accept`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await Self.receiveOffer(client: client, mock: mock)

            try await module.acceptFileTransfer(sid: "sid-123")
            await #expect(throws: JingleModule.JingleError.alreadyAccepted) {
                try await module.acceptFileTransfer(sid: "sid-123")
            }

            let sessionAccepts = await mock.sentBytes.filter { String(decoding: $0, as: UTF8.self).contains("session-accept") }
            #expect(sessionAccepts.count == 1)
            await disconnectFast(client)
        }

        @Test
        func `An accept whose session-accept failed to send can be retried`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await Self.receiveOffer(client: client, mock: mock)

            await mock.simulateSendFailure(XMPPClientError.sendFailed("The connection was closed"))
            await #expect(throws: (any Error).self) {
                try await module.acceptFileTransfer(sid: "sid-123")
            }
            await mock.simulateSendFailure(nil)

            try await module.acceptFileTransfer(sid: "sid-123")
            await disconnectFast(client)
        }

        @Test
        func `A second transport wait fails without displacing the first`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await Self.receiveOffer(client: client, mock: mock)

            let firstWait = Task { try await module.awaitTransportReady(sid: "sid-123") }
            try await Task.sleep(for: .milliseconds(100))
            let second = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-123") }
            guard case let .failure(error)? = second else {
                Issue.record("Expected the second wait to fail, got \(String(describing: second))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .transportFailed("The transfer is already waiting for a connection"))

            await mock.simulateReceive(transportReplaceXML())
            let first = try await boundedOutcome { try await firstWait.value }
            guard case .success? = first else {
                Issue.record("Expected the first wait to resolve, got \(String(describing: first))")
                await disconnectFast(client)
                return
            }
            await disconnectFast(client)
        }
    }

    struct SessionTerminateSuccess {
        @Test
        func `A success terminate on a receive with nothing to claim fails as incomplete`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            await mock.simulateReceive(sessionTerminateXML(reason: "success"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == .incomplete)
            #expect(!events.contains { if case .jingleFileTransferCompleted = $0 { true } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A success terminate on a sending session before any send fails as canceled`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()

            var reason = XMLElement(name: "reason")
            reason.addChild(XMLElement(name: "success"))
            try harness.receive(action: "session-terminate", sid: sid, payload: [reason])
            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, .cancel) = $0 { true } else { false } } != nil)
        }
    }

    struct SessionTerminateFailure {
        @Test
        func `Emits jingleFileTransferFailed on session-terminate with cancel reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))
            await mock.simulateReceive(sessionTerminateXML(reason: "cancel"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == .cancel)

            await disconnectFast(client)
        }

        @Test
        func `A non-success terminate after accept fails with the peer's reason before any claim`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try await harness.module.acceptFileTransfer(sid: "sid-1")

            try harness.receive(action: "session-terminate", sid: "sid-1", payload: [JingleInitiatorHarness.reason("connectivity-error")])
            let failure = try await harness.event { event in
                if case .jingleFileTransferFailed("sid-1", .connectivityError) = event { return true }
                return false
            }
            #expect(failure != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
        }
    }

    struct DeclineFileTransfer {
        @Test
        func `declineFileTransfer sends session-terminate with decline reason`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            // Simulate receiving a session-initiate
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Decline the transfer
            try await module.declineFileTransfer(sid: "sid-123")
            try? await Task.sleep(for: .milliseconds(100))

            // Verify session-terminate was sent with decline reason
            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }
            let terminateIQ = sentStrings.first { $0.contains("session-terminate") }
            #expect(terminateIQ != nil)
            #expect(terminateIQ?.contains("<decline/>") == true)

            await disconnectFast(client)
        }
    }

    struct IBBOpenHandshake {
        @Test
        func `Incoming IBB open is acknowledged`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Simulate session-initiate + transport-replace to set up IBB
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }

            let ackIQ = await awaitSentResponse(
                on: mock,
                afterReceiving: """
                <iq type='set' id='ibb-open-1' from='peer@example.com/res'>\
                <open xmlns='http://jabber.org/protocol/ibb' sid='ibb-fallback' block-size='4096' stanza='iq'/>\
                </iq>
                """,
                matching: { $0.contains("type=\"result\"") && $0.contains("ibb-open-1") }
            )
            #expect(ackIQ != nil)

            await disconnectFast(client)
        }
    }

    struct DisconnectClearsSession {
        @Test
        func `handleDisconnect clears sessions and emits failed events`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Simulate receiving a session-initiate
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            // Collect events including the disconnect-triggered failure
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            await disconnectFast(client)

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event on disconnect")
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == .disconnected)
        }
    }

    struct SessionInitiateOfferingNoFile {
        @Test(arguments: [JingleContentSenders.responder, .none])
        func `A session-initiate that offers no file is declined without a session`(senders: JingleContentSenders) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1", senders: senders)

            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "initiate-sid-1", type: "result")) != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "decline") != nil)
            #expect(harness.eventCount { _ in true } == 0)

            // No session holds the sid, so an offer reusing it is received.
            try harness.receive(
                action: "session-initiate", sid: "sid-1",
                payload: [JingleInitiatorHarness.fileContent(JingleFileDescription(name: "test.txt", size: 3))], id: "offer"
            )
            #expect(try await harness.event { if case .jingleFileTransferReceived = $0 { true } else { false } } != nil)
        }

        @Test
        func `A session-initiate offering part of a file is declined without a session`() async throws {
            let harness = JingleInitiatorHarness()
            let file = JingleFileDescription(name: "test.txt", size: 5, range: JingleFileRange(offset: 2))
            try harness.receiveOffer(sid: "sid-1", file: file)

            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "decline") != nil)
            #expect(harness.eventCount { _ in true } == 0)
        }

        @Test
        func `A session-initiate reusing a live sid is refused with a tie-break conflict`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try harness.receiveOffer(sid: "sid-1")

            let reply = try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "initiate-sid-1", type: "error"))
            let error = reply?.child(named: "error")
            #expect(error?.child(named: "conflict") != nil)
            #expect(error?.child(named: "tie-break", namespace: XMPPNamespaces.jingleErrors) != nil)
        }
    }

    struct OfferInitiation {
        @Test
        func `Offers carry random session IDs`() async throws {
            let harness = JingleInitiatorHarness()
            let first = try await harness.initiate()
            let second = try await harness.initiate()

            #expect(first != second)
            #expect(first.count == 32)
            #expect(!first.hasPrefix("id-"))
        }

        @Test(arguments: [
            ["offset": "2"],
            // The offer is 3 bytes, so a shorter length is a slice just as an offset is — and this is the branch a
            // resuming peer actually sends.
            ["length": "1"],
            // An attribute that will not parse counts as a slice rather than as absent: a peer must not win the whole
            // file by sending a range this side cannot read.
            ["offset": "not-a-number"],
            ["length": "not-a-number"]
        ])
        func `A session-accept asking for part of the file fails the session`(rangeAttributes: [String: String]) async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()

            // Content that does not parse must not carry a range past the check either: name, size and transport are
            // all absent here.
            var file = XMLElement(name: "file")
            file.addChild(XMLElement(name: "range", attributes: rangeAttributes))
            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)
            var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            content.addChild(description)
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [content])

            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)
        }

        /// A decline is the peer's answer, so whoever waits on the session is told that rather than that the session
        /// went missing.
        @Test
        func `A peer's decline reaches the waiting sender as the decline`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            let wait = Task { try await harness.module.awaitTransportReady(sid: sid) }
            try await Task.sleep(for: .milliseconds(100))
            // Armed: a second wait is refused only while the first is parked, so the terminate lands on a waiting sender.
            let probe = try await boundedOutcome { try await harness.module.awaitTransportReady(sid: sid) }
            guard case let .failure(probeError)? = probe,
                  probeError as? JingleModule.JingleError == .transportFailed("The transfer is already waiting for a connection") else {
                Issue.record("Expected the first wait to be parked, got \(String(describing: probe))")
                return
            }

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("decline")])

            await #expect(throws: JingleModule.JingleError.transportFailed("The contact declined the transfer")) {
                try await wait.value
            }
        }

        /// A peer can end a session and offer again under the same sid. The accept the user gave the first offer names
        /// that offer, so it must not take the second.
        @Test
        func `An accept for an offer whose sid was reused does not take the new offer`() async throws {
            let harness = JingleInitiatorHarness()
            let file = JingleInitiatorHarness.fileContent(JingleFileDescription(name: "first.txt", size: 3))
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-reuse", payload: [file], id: "initiate-1")
            let first = try #require(harness.receivedOffers().first)
            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: "sid-reuse", payload: [JingleInitiatorHarness.reason("cancel")])
            let other = JingleInitiatorHarness.fileContent(JingleFileDescription(name: "second.txt", size: 3))
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-reuse", payload: [other], id: "initiate-2")
            let offers = harness.receivedOffers()
            try #require(offers.count == 2)
            #expect(offers[0].offerID != offers[1].offerID)

            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.acceptFileTransfer(sid: "sid-reuse", offerID: first.offerID)
            }
            #expect(harness.sentJingleCount(action: JingleAction.sessionAccept.rawValue) == 0)

            // The offer now under the sid can still be accepted by its own id.
            try await harness.module.acceptFileTransfer(sid: "sid-reuse", offerID: offers[1].offerID)
            #expect(harness.sentJingleCount(action: JingleAction.sessionAccept.rawValue) == 1)
        }

        /// A decline, a transport wait and a receive for the first offer name that offer too, so none of them reaches the
        /// offer now holding its sid.
        @Test
        func `A decline, wait or receive for an offer whose sid was reused leaves the new offer alone`() async throws {
            let harness = JingleInitiatorHarness()
            let file = JingleInitiatorHarness.fileContent(JingleFileDescription(name: "first.txt", size: 3))
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-reuse", payload: [file], id: "initiate-1")
            let first = try #require(harness.receivedOffers().first)
            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: "sid-reuse", payload: [JingleInitiatorHarness.reason("cancel")])
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-reuse", payload: [file], id: "initiate-2")
            let second = try #require(harness.receivedOffers().last)
            try #require(first.offerID != second.offerID)

            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.declineFileTransfer(sid: "sid-reuse", offerID: first.offerID)
            }
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
            // Bounded: a wait that took the new session would park until that session got a transport.
            let module = harness.module
            let wait = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-reuse", offerID: first.offerID) }
            guard case let .failure(waitError)? = wait else {
                Issue.record("Expected the wait to fail at once, got \(String(describing: wait))")
                return
            }
            #expect(waitError as? JingleModule.JingleError == .sessionNotFound)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await harness.module.receiveFileData(sid: "sid-reuse", offerID: first.offerID)
            }

            // The offer now under the sid is still there to decline by its own id.
            try await harness.module.declineFileTransfer(sid: "sid-reuse", offerID: second.offerID)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 1)
        }

        /// XEP-0260 §2.2: the responder must not offer any host and port the initiator already offered.
        @Test
        func `A session-accept does not echo the initiator's candidates`() async throws {
            let harness = JingleInitiatorHarness()
            let candidate = SOCKS5Transport.Candidate(
                cid: "peer-direct", host: "127.0.0.1", port: 9, jid: JingleInitiatorHarness.peer.description,
                priority: 1, type: .direct
            )
            let offer = JingleContent(
                name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
                transport: .socks5(SOCKS5Transport(sid: "transport-sid", candidates: [candidate]))
            )
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-echo", payload: [offer.toXML()], id: "initiate-echo")

            try await harness.module.acceptFileTransfer(sid: "sid-echo")

            // Armed: the accept went out and still carries its transport, so the empty list below is not a missing stanza.
            let accepted = try #require(harness.offeredContent(action: JingleAction.sessionAccept.rawValue, sid: "sid-echo"))
            #expect(accepted.child(named: "transport")?.attribute("sid") == "transport-sid")
            #expect(harness.offeredCandidates(action: JingleAction.sessionAccept.rawValue, sid: "sid-echo").isEmpty)
        }

        @Test
        func `An offer the peer rejects ends its session and throws`() async throws {
            let harness = JingleInitiatorHarness { iq in
                guard iq.child(named: "jingle")?.attribute("action") == JingleAction.sessionInitiate.rawValue else { return nil }
                throw XMPPStanzaError(errorType: .cancel, condition: .conflict)
            }

            await #expect(throws: JingleModule.JingleError.transportNegotiationFailed(XMPPStanzaError(errorType: .cancel, condition: .conflict).displayText)) {
                _ = try await harness.initiate()
            }
            let initiate = try #require(try await harness.sentIQ { $0.child(named: "jingle")?.attribute("action") == JingleAction.sessionInitiate.rawValue })
            let sid = try #require(initiate.child(named: "jingle")?.attribute("sid"))
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.awaitTransportReady(sid: sid)
            }
            #expect(harness.eventCount { _ in true } == 0)
        }
    }

    struct SessionInitiateWithSendersInitiator {
        @Test
        func `Emits jingleFileTransferReceived when senders is initiator`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML(senders: "initiator"))

            let events = try await eventsTask.value
            guard case let .jingleFileTransferReceived(offer) = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await disconnectFast(client)
                return
            }
            #expect(offer.sid == "sid-123")

            await disconnectFast(client)
        }
    }

    struct SessionInitiateWithoutSenders {
        @Test
        func `Emits jingleFileTransferReceived when senders absent (defaults to both)`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            guard case .jingleFileTransferReceived = events.last else {
                Issue.record("Expected jingleFileTransferReceived event")
                await disconnectFast(client)
                return
            }

            await disconnectFast(client)
        }
    }

    struct SessionInfoChecksum {
        @Test
        func `Emits jingleChecksumReceived on session-info with checksum`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleChecksumReceived = event { return true }
                    return false
                }
            }

            // Create a session first
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(100))

            // Send session-info with checksum
            await mock.simulateReceive(sessionInfoChecksumXML(hash: "dGVzdA=="))

            let events = try await eventsTask.value
            guard case let .jingleChecksumReceived(sid, checksum) = events.last else {
                Issue.record("Expected jingleChecksumReceived event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-123")
            #expect(checksum.algo == "sha-256")
            #expect(checksum.hash == "dGVzdA==")
            #expect(checksum.contentName == "a-file-offer")

            await disconnectFast(client)
        }
    }

    struct VerifyChecksumMatch {
        private static func info(_ algo: String, _ hash: String) -> JingleChecksumInfo {
            JingleChecksumInfo(contentName: "a-file-offer", algo: algo, hash: hash)
        }

        @Test
        func `verifyChecksum returns verified when checksum matches`() {
            let result = JingleModule.verifyChecksum(Self.info("sha-256", "A5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc+4E="), data: [1, 2, 3])
            #expect(result == .verified)
        }

        @Test
        func `verifyChecksum returns mismatch when checksum differs`() {
            let result = JingleModule.verifyChecksum(Self.info("sha-256", "wronghash=="), data: [1, 2, 3])
            #expect(result == .mismatch(expected: "wronghash==", computed: "A5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc+4E="))
        }

        @Test
        func `verifyChecksum returns unsupportedAlgorithm for non-sha256`() {
            let result = JingleModule.verifyChecksum(Self.info("sha-512", "somehash=="), data: [1, 2, 3])
            #expect(result == .unsupportedAlgorithm("sha-512"))
        }

        @Test
        func `A checksum sent before acceptance is verified when the receive finalizes`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try harness.receive(action: "session-info", sid: "sid-1", payload: [JingleInitiatorHarness.checksum("wronghash==")])
            try await harness.module.acceptFileTransfer(sid: "sid-1")
            try harness.receive(action: "transport-replace", sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            await #expect(throws: JingleModule.JingleError.transportFailed("The received file is corrupted")) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", .checksumMismatch) = $0 { true } else { false } } == 1)
        }
    }

    struct IBBTransportFailure {
        private static func makeContext(failingWith error: any Error) -> ModuleContext {
            makeStubModuleContext(sendIQ: { _, _ in throw error })
        }

        @Test
        func `An IBB stanza error surfaces as a readable transport failure`() async {
            let context = Self.makeContext(failingWith: XMPPStanzaError(errorType: .cancel, condition: .itemNotFound))
            await #expect(throws: JingleModule.JingleError.transportFailed("The requested item was not found")) {
                try await JingleModule().sendJingleIQ(XMPPIQ(type: .set), context: context, failure: JingleModule.JingleError.transportFailed)
            }
        }

        @Test
        func `An IBB exchange without a connection surfaces as not connected`() async {
            let context = Self.makeContext(failingWith: XMPPClientError.notConnected)
            await #expect(throws: JingleModule.JingleError.notConnected) {
                try await JingleModule().sendJingleIQ(XMPPIQ(type: .set), context: context, failure: JingleModule.JingleError.transportFailed)
            }
        }

        @Test
        func `An unanswered IBB exchange surfaces as a readable transport failure`() async {
            let context = Self.makeContext(failingWith: XMPPClientError.timeout)
            await #expect(throws: JingleModule.JingleError.transportFailed("The contact did not respond in time")) {
                try await JingleModule().sendJingleIQ(XMPPIQ(type: .set), context: context, failure: JingleModule.JingleError.transportFailed)
            }
        }

        @Test
        func `An IBB exchange that cannot be sent surfaces as a readable transport failure`() async {
            let context = Self.makeContext(failingWith: XMPPClientError.sendFailed("Broken pipe"))
            await #expect(throws: JingleModule.JingleError.transportFailed("Broken pipe")) {
                try await JingleModule().sendJingleIQ(XMPPIQ(type: .set), context: context, failure: JingleModule.JingleError.transportFailed)
            }
        }
    }

    struct SOCKS5TransportFailure {
        @Test
        func `SOCKS5 send failure surfaces as a readable transport failure`() async {
            let module = JingleModule()
            await #expect(throws: JingleModule.JingleError.transportFailed("The connection is not open")) {
                try await module.sendSOCKS5Data(
                    sid: "sid-123", data: [1, 2, 3], connection: SOCKS5Connection(), context: makeStubModuleContext()
                )
            }
        }

        @Test
        func `SOCKS5 receive failure surfaces as a readable transport failure`() async {
            let module = JingleModule()
            await #expect(throws: JingleModule.JingleError.transportFailed("The connection is not open")) {
                _ = try await module.receiveSOCKS5Data(
                    sid: "sid-123", expectedSize: 3, connection: SOCKS5Connection(), context: makeStubModuleContext()
                )
            }
        }
    }

    struct ContentAddHandling {
        @Test
        func `A content-add is answered with a content-reject and reports nothing`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            let added = JingleContent(
                name: "file-1", creator: "initiator", description: JingleFileDescription(name: "extra.pdf", size: 5),
                transport: .socks5(SOCKS5Transport(sid: "transport-2"))
            )
            try harness.receive(action: "content-add", sid: "sid-1", payload: [added.toXML()])

            let reject = try #require(try await harness.sentJingle(action: JingleAction.contentReject.rawValue))
            let content = reject.child(named: "jingle")?.child(named: "content")
            #expect(content?.attribute("name") == "file-1")
            #expect(content?.attribute("creator") == "initiator")
            // Only the session's own offer is reported.
            #expect(harness.eventCount { if case .jingleFileTransferReceived = $0 { true } else { false } } == 1)
        }
    }

    struct ContentRejectHandling {
        @Test(arguments: [JingleAction.contentAccept.rawValue, JingleAction.contentReject.rawValue])
        func `A content-accept or content-reject gets one out-of-order error and no result`(action: String) async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            let content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "file-1"])
            try harness.receive(action: action, sid: "sid-1", payload: [content], id: "content-iq")
            try await harness.expectSingleOutOfOrderError(to: "content-iq", sid: "sid-1")
        }
    }

    struct ContentRemoveHandling {
        @Test
        func `Removing a content other than the primary gets one out-of-order error`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            let content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "file-1"])
            try harness.receive(action: "content-remove", sid: "sid-1", payload: [content], id: "remove-iq")
            try await harness.expectSingleOutOfOrderError(to: "remove-iq", sid: "sid-1")
            #expect(harness.eventCount { if case .jingleFileTransferFailed = $0 { true } else { false } } == 0)
        }

        @Test
        func `Removing the primary content acknowledges and fails the transfer once as canceled`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            let content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            try harness.receive(action: "content-remove", sid: "sid-1", payload: [content], id: "remove-iq")

            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "remove-iq", type: "result")) != nil)
            let failure = try await harness.event { event in
                if case .jingleFileTransferFailed("sid-1", .cancel) = event { return true }
                return false
            }
            #expect(failure != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "cancel") != nil)

            try harness.receive(action: "content-remove", sid: "sid-1", payload: [content], id: "remove-again")
            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "remove-again", type: "error")) != nil)
            #expect(harness.eventCount { if case .jingleFileTransferFailed = $0 { true } else { false } } == 1)
        }
    }

    struct SenderVerification {
        private static let foreignJID = "mallory@example.com/evil"

        /// The `<error>` element of a sent IQ error, with its attributes and children in order.
        private static func errorElement(_ stanza: String?) -> Substring? {
            guard let stanza, let start = stanza.range(of: "<error"), let end = stanza.range(of: "</error>") else { return nil }
            return stanza[start.lowerBound ..< end.upperBound]
        }

        @Test
        func `A terminate from a foreign sender gets unknown-session and leaves the session live`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            await mock.simulateReceive(sessionInitiateXML())

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .jingleFileTransferReceived(offer) = event, offer.sid == "sid-next" { return true }
                    return false
                }
            }
            let reply = await awaitSentResponse(
                on: mock,
                afterReceiving: sessionTerminateXML(id: "foreign-1", from: Self.foreignJID, reason: "cancel"),
                matching: { $0.contains("foreign-1") && $0.contains("type=\"error\"") }
            )
            #expect(reply?.contains("item-not-found") == true)
            #expect(reply?.contains("unknown-session") == true)
            #expect(reply?.contains("urn:xmpp:jingle:errors:1") == true)
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-next", sid: "sid-next"))
            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })

            let legitimate = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed("sid-123", .cancel) = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionTerminateXML(reason: "cancel"))
            _ = try await legitimate.value
            await disconnectFast(client)
        }

        @Test
        func `An unknown sid gets the same error as a foreign sender`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            await mock.simulateReceive(sessionInitiateXML())

            let foreign = await awaitSentResponse(
                on: mock,
                afterReceiving: sessionTerminateXML(id: "probe", from: Self.foreignJID, reason: "cancel"),
                matching: { $0.contains("probe") && $0.contains("type=\"error\"") }
            )
            let unknown = await awaitSentResponse(
                on: mock,
                afterReceiving: sessionTerminateXML(id: "probe", sid: "no-such-sid", reason: "cancel"),
                matching: { $0.contains("probe") && $0.contains("type=\"error\"") }
            )
            let foreignError = try #require(Self.errorElement(foreign))
            #expect(foreignError == Self.errorElement(unknown))
            await disconnectFast(client)
        }

        @Test
        func `The peer's bare JID with another resource is rejected`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            let otherResource = try #require(FullJID.parse("peer@example.com/other"))

            try harness.receive(action: "session-terminate", sid: "sid-1", payload: [XMLElement(name: "reason")], id: "other", from: otherResource)
            let error = try #require(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "other", type: "error")))
            #expect(error.child(named: "error")?.child(named: "unknown-session", namespace: XMPPNamespaces.jingleErrors) != nil)
            // RFC 6120 §8.3.1: the reply carries the payload it refuses.
            #expect(error.child(named: "jingle")?.attribute("sid") == "sid-1")
            #expect(harness.eventCount { if case .jingleFileTransferFailed = $0 { true } else { false } } == 0)
        }

        @Test
        func `A session-initiate for a live sid gets conflict and keeps the original peer`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            let intruder = try #require(FullJID.parse(Self.foreignJID))

            try harness.receive(
                action: "session-initiate", sid: "sid-1",
                payload: [JingleInitiatorHarness.fileContent(JingleFileDescription(name: "evil.txt", size: 9))],
                id: "hijack", from: intruder
            )
            let error = try #require(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "hijack", type: "error")))
            #expect(error.child(named: "error")?.attribute("type") == "cancel")
            #expect(error.child(named: "error")?.child(named: "conflict", namespace: XMPPNamespaces.stanzas) != nil)

            var reason = XMLElement(name: "reason")
            reason.addChild(XMLElement(name: "decline"))
            try harness.receive(action: "session-terminate", sid: "sid-1", payload: [reason])
            #expect(try await harness.event { if case .jingleFileTransferFailed("sid-1", .decline) = $0 { true } else { false } } != nil)
        }

        /// An offer this side cannot parse is declined to the peer, so the peer stops waiting for an accept instead of
        /// holding a session this side dropped.
        @Test
        func `A session-initiate whose content will not parse is declined to the peer`() async throws {
            let harness = JingleInitiatorHarness()
            var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            content.addChild(XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer))
            try harness.receive(action: "session-initiate", sid: "bad-sid", payload: [content], id: "initiate-bad")

            let terminate = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue))
            #expect(terminate.child(named: "jingle")?.child(named: "reason")?.child(named: "decline") != nil)
            #expect(harness.eventCount { if case .jingleFileTransferReceived = $0 { true } else { false } } == 0)
        }

        @Test(arguments: [
            (Int64(-1), ""),
            (Int64(10), "<range offset='-1'/>"),
            (Int64(10), "<range length='-1'/>"),
            (Int64(10), "<range offset='11'/>"),
            (Int64(10), "<range offset='5' length='6'/>"),
            // A slice of a file this side cannot resume.
            (Int64(10), "<range offset='2'/>"),
            (Int64(10), "<range length='6'/>"),
            // An attribute that will not parse counts as a range this side cannot honour rather than as absent.
            (Int64(10), "<range offset='not-a-number'/>"),
            (Int64(10), "<range length='not-a-number'/>")
        ])
        func `A session-initiate with an invalid size or range emits no offer`(size: Int64, rangeXML: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .jingleFileTransferReceived(offer) = event, offer.sid == "sid-next" { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML(fileSize: size, rangeXML: rangeXML))
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-next", sid: "sid-next"))

            let events = try await eventsTask.value
            #expect(!events.contains { if case let .jingleFileTransferReceived(offer) = $0 { offer.sid == "sid-123" } else { false } })
            await disconnectFast(client)
        }

        /// The control for the matrix above: a range that names the whole file is what a peer advertising range support
        /// sends, and refusing it would make that matrix pass by declining everything.
        @Test(arguments: ["", "<range/>", "<range offset='0'/>", "<range length='10'/>", "<range offset='0' length='10'/>"])
        func `A session-initiate whose range names the whole file still emits an offer`(rangeXML: String) async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .jingleFileTransferReceived(offer) = event, offer.sid == "sid-123" { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML(fileSize: 10, rangeXML: rangeXML))

            let events = try await eventsTask.value
            #expect(events.contains { if case let .jingleFileTransferReceived(offer) = $0 { offer.sid == "sid-123" } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A session-accept with another size on a responder session leaves the frozen size`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")
            try await harness.module.acceptFileTransfer(sid: "sid-1")
            try harness.receive(action: "transport-replace", sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
            try harness.receive(
                action: "session-accept", sid: "sid-1",
                payload: [JingleInitiatorHarness.fileContent(JingleFileDescription(name: "test.txt", size: 5))]
            )

            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount { if case .jingleFileTransferCompleted("sid-1", .ibb) = $0 { true } else { false } } == 1)
        }
    }
}
