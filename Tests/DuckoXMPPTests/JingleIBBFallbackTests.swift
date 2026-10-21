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

/// Builds a session-initiate IQ XML string with S5B transport.
private func sessionInitiateXML(
    id: String = "jingle-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res",
    size: Int = 1024
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>test.txt</name>\
    <size>\(size)</size>\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-replace IQ with IBB transport.
private func transportReplaceXML(
    id: String = "tr-1",
    sid: String = "sid-ibb-test",
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

/// Builds a content-remove IQ for the session's only content.
private func contentRemoveXML(
    id: String = "content-remove-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='content-remove' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'/>\
    </jingle>\
    </iq>
    """
}

/// Builds an IBB data IQ.
private func ibbDataXML(
    id: String = "ibb-data-1",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback",
    seq: UInt16 = 0,
    base64Data: String = "AQID"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <data xmlns='http://jabber.org/protocol/ibb' sid='\(ibbSID)' seq='\(seq)'>\(base64Data)</data>\
    </iq>
    """
}

/// Builds an IBB close IQ.
private func ibbCloseXML(
    id: String = "ibb-close-1",
    from: String = "peer@example.com/res",
    ibbSID: String = "ibb-fallback"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <close xmlns='http://jabber.org/protocol/ibb' sid='\(ibbSID)'/>\
    </iq>
    """
}

/// Builds a session-terminate IQ.
private func sessionTerminateXML(
    id: String = "jingle-terminate-1",
    sid: String = "sid-ibb-test",
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

/// Builds a transport-info IQ with a SOCKS5 candidate-error.
private func candidateErrorXML(
    id: String = "ti-error-1",
    sid: String = "sid-ibb-test",
    from: String = "peer@example.com/res"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'><candidate-error/></transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

// MARK: - Tests

enum JingleIBBFallbackTests {
    struct TransportReplaceTriggersAccept {
        @Test
        func `Receiving transport-replace with IBB triggers transport-accept response`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create a session first
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Receive transport-replace with IBB
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }

            // Should have sent transport-accept
            let acceptIQ = sentStrings.first { $0.contains("transport-accept") }
            #expect(acceptIQ != nil)
            #expect(acceptIQ?.contains("urn:xmpp:jingle:transports:ibb:1") == true)

            await disconnectFast(client)
        }
    }

    struct TransportReject {
        @Test
        func `A reject of this side's IBB fallback emits a failure and fails later transport waits`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            try harness.receive(action: JingleAction.transportReject.rawValue, sid: sid, id: "expected-reject")
            let failure = try await harness.event { if case .jingleFileTransferFailed(sid, .transportReject) = $0 { true } else { false } }
            #expect(failure != nil)
            try await harness.expectSingleReply(to: "expected-reject", type: "result", sid: sid)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "failed-transport") != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.awaitTransportReady(sid: sid)
            }
        }

        /// A reject answers a replace this side proposed. One nobody asked for is refused and ends nothing.
        @Test
        func `An unrequested transport-reject is refused and leaves the offer in place`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1")

            try harness.receive(action: JingleAction.transportReject.rawValue, sid: "sid-1", id: "unrequested-reject")
            try await harness.expectSingleOutOfOrderError(to: "unrequested-reject", sid: "sid-1")
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
            try await harness.module.acceptFileTransfer(sid: "sid-1")
        }
    }

    struct TransportReplaceSendFailure {
        @Test
        func `A transport-replace that fails to send abandons the transport`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.transportReplace.rawValue])
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))])
            let failure = try await harness.event { event in
                if case .jingleFileTransferFailed(_, .transportReplaceFailed) = event { return true }
                return false
            }
            #expect(failure != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "failed-transport") != nil)

            // The failed proposal already installed IBB state, so only removing the abandoned session can fail this wait.
            let outcome = try await boundedOutcome { try await harness.module.awaitTransportReady(sid: sid) }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the wait to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .sessionNotFound)
        }
    }

    struct AbandonedIBBTransfer {
        @Test
        func `Abandoning a transport ends a pending IBB receive and ignores a later close`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            let receiveTask = Task { try await module.receiveFileData(sid: "sid-ibb-test") }
            try await Task.sleep(for: .milliseconds(100))

            let abandoned = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(contentRemoveXML())
            _ = try await abandoned.value

            let outcome = try await boundedOutcome { _ = try await receiveTask.value }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the receive to fail, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            #expect(error as? JingleModule.JingleError == .transportNegotiationFailed("The transfer was canceled"))

            // The offer that follows the close marks the point by which a completion would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(ibbCloseXML())
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-2", sid: "sid-next"))
            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferCompleted = $0 { true } else { false } })
            let closeError = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("ibb-close-1") && $0.contains("item-not-found") }
            }
            #expect(closeError != nil)
            await disconnectFast(client)
        }

        @Test
        func `A transport-replace with an invalid block size is rejected`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML(blockSize: 0))
            let rejectSent = try await boundedOutcome {
                _ = await mock.waitForSent { $0.contains("transport-reject") }
            }
            #expect(rejectSent != nil)
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("transport-accept") })
            await disconnectFast(client)
        }
    }

    struct DisconnectAfterAbandon {
        @Test
        func `A disconnect reports no second failure for an abandoned transport`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.transportReplace.rawValue])
            let abandonedSID = try await harness.initiate()
            let liveSID = try await harness.initiate()
            try harness.receive(
                action: "transport-info", sid: abandonedSID, payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )
            let abandoned = try await harness.event { event in
                if case .jingleFileTransferFailed(abandonedSID, .transportReplaceFailed) = event { return true }
                return false
            }
            #expect(abandoned != nil)

            await harness.module.handleDisconnect()
            // The live session's failure shows the disconnect reported failures at all.
            let live = try await harness.event { event in
                if case .jingleFileTransferFailed(liveSID, .disconnected) = event { return true }
                return false
            }
            #expect(live != nil)
            let repeated = try await harness.event(timeout: .zero) { event in
                if case .jingleFileTransferFailed(abandonedSID, .disconnected) = event { return true }
                return false
            }
            #expect(repeated == nil)
        }
    }

    struct TransportWaitAfterFallback {
        @Test
        func `A transport wait after IBB fallback is established resolves at once`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }

            let outcome = try await boundedOutcome { try await module.awaitTransportReady(sid: "sid-ibb-test") }
            guard case .success? = outcome else {
                Issue.record("Expected the wait to resolve, got \(String(describing: outcome))")
                await disconnectFast(client)
                return
            }
            await disconnectFast(client)
        }
    }

    struct StaleCandidateError {
        @Test
        func `A candidate-error after IBB fallback reports no failure`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // The offer that follows the candidate-error marks the point by which a failure would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case let .jingleFileTransferReceived(offer) = event, offer.sid == "sid-next" { return true }
                    return false
                }
            }
            await mock.simulateReceive(sessionInitiateXML())
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            // The initiator's own SOCKS5 attempt fails after it already switched to IBB.
            await mock.simulateReceive(candidateErrorXML())
            await mock.simulateReceive(sessionInitiateXML(id: "jingle-2", sid: "sid-next"))

            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
            await disconnectFast(client)
        }

        @Test
        func `A candidate-error for an unknown session reports no failure`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // The offer that follows the candidate-error marks the point by which a failure would have been reported.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferReceived = event { return true }
                    return false
                }
            }
            await mock.simulateReceive(candidateErrorXML(sid: "ended-sid"))
            await mock.simulateReceive(sessionInitiateXML())

            let events = try await eventsTask.value
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
            await disconnectFast(client)
        }
    }

    struct IBBDataAcknowledged {
        @Test
        func `IBB data IQ is acknowledged with IQ result`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session, accept it, and establish IBB transport
            await mock.simulateReceive(sessionInitiateXML())
            try? await Task.sleep(for: .milliseconds(200))
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await module.acceptFileTransfer(sid: "sid-ibb-test")
            await mock.simulateReceive(transportReplaceXML())
            try? await Task.sleep(for: .milliseconds(200))

            await mock.clearSentBytes()

            // Send IBB data
            await mock.simulateReceive(ibbDataXML())
            try? await Task.sleep(for: .milliseconds(200))

            let sentData = await mock.sentBytes
            let sentStrings = sentData.map { String(decoding: $0, as: UTF8.self) }

            // Should have sent IQ result acknowledging the data
            let ackIQ = sentStrings.first { $0.contains("type=\"result\"") && $0.contains("ibb-data-1") }
            #expect(ackIQ != nil)

            await disconnectFast(client)
        }
    }

    struct IBBCloseEmitsCompletion {
        @Test
        func `IBB close after full data and a claim emits jingleFileTransferCompleted with .ibb`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferCompleted = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML(size: 3))
            try? await Task.sleep(for: .milliseconds(200))
            // Bytes only flow after the user accepts, so the transfer is accepted before the transport switches.
            try await module.acceptFileTransfer(sid: "sid-ibb-test")
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            await mock.simulateReceive(ibbDataXML())
            let receiveTask = Task { try await module.receiveFileData(sid: "sid-ibb-test") }
            await mock.simulateReceive(ibbCloseXML())

            #expect(try await receiveTask.value == [1, 2, 3])
            let events = try await eventsTask.value
            guard case let .jingleFileTransferCompleted(sid, transport) = events.last else {
                Issue.record("Expected jingleFileTransferCompleted event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-ibb-test")
            #expect(transport == .ibb)

            await disconnectFast(client)
        }
    }

    struct IBBCloseFollowedByTerminateEmitsOnce {
        @Test
        func `IBB close then session-terminate(success) emits exactly one completion`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)
            let module = try #require(await client.module(ofType: JingleModule.self))

            // Use disconnect as a sentinel to stop event collection — collect
            // every event up to and including the disconnect event.
            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .disconnected = event { return true }
                    return false
                }
            }

            await mock.simulateReceive(sessionInitiateXML(size: 3))
            try? await Task.sleep(for: .milliseconds(200))
            // Bytes only flow after the user accepts, so the transfer is accepted before the transport switches.
            try await module.acceptFileTransfer(sid: "sid-ibb-test")
            await mock.simulateReceive(transportReplaceXML())
            _ = await mock.waitForSent { $0.contains("transport-accept") }
            await mock.simulateReceive(ibbDataXML())
            let receiveTask = Task { try await module.receiveFileData(sid: "sid-ibb-test") }
            await mock.simulateReceive(ibbCloseXML())
            await mock.simulateReceive(sessionTerminateXML(reason: "success"))
            #expect(try await receiveTask.value == [1, 2, 3])
            try? await Task.sleep(for: .milliseconds(100))

            await disconnectFast(client)

            let events = try await eventsTask.value
            let completions = events.filter {
                if case .jingleFileTransferCompleted = $0 { return true }
                return false
            }
            #expect(completions.count == 1)
            if case let .jingleFileTransferCompleted(completedSID, transport) = completions.first {
                #expect(completedSID == "sid-ibb-test")
                #expect(transport == .ibb)
            }
            #expect(!events.contains { if case .jingleFileTransferFailed = $0 { true } else { false } })
        }
    }

    // MARK: - Harness Helpers

    private static let received = XMLElement(name: "received", namespace: XMPPNamespaces.jingleFileTransfer)

    /// Delivers the peer's offer, accepts it and switches it to IBB, so this side receives over IBB. The accept is part
    /// of the flow: bytes that arrive before one are refused, so a helper that skipped it would not be a real receive.
    private static func startIBBReceive(
        _ harness: JingleInitiatorHarness, sid: String = "sid-1", file: JingleFileDescription = JingleFileDescription(name: "test.txt", size: 3)
    ) async throws {
        try harness.receiveOffer(sid: sid, file: file)
        try await harness.module.acceptFileTransfer(sid: sid)
        try harness.receive(action: "transport-replace", sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
    }

    /// Starts a transfer this side sends and switches it to IBB.
    private static func startIBBSend(_ harness: JingleInitiatorHarness) async throws -> String {
        let sid = try await harness.initiate()
        try harness.receive(action: "transport-replace", sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
        return sid
    }

    struct IBBSenderVerification {
        @Test
        func `IBB stanzas from a foreign sender or for an unknown stream get item-not-found`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            let foreign = try #require(FullJID.parse("mallory@example.com/evil"))

            let peer = JingleInitiatorHarness.peer
            let foreignStanzas: [String: XMLElement] = [
                "foreign-open": JingleInitiatorHarness.ibbOpen(),
                "foreign-data": JingleInitiatorHarness.ibbData([9, 9, 9], seq: 0),
                "foreign-close": JingleInitiatorHarness.ibbClose()
            ]
            let unknownStreamStanzas: [String: XMLElement] = [
                "unknown-open": JingleInitiatorHarness.ibbOpen(ibbSID: "other"),
                "unknown-data": JingleInitiatorHarness.ibbData([9, 9, 9], seq: 0, ibbSID: "other"),
                "unknown-close": JingleInitiatorHarness.ibbClose(ibbSID: "other")
            ]
            for (stanzas, sender) in [(foreignStanzas, foreign), (unknownStreamStanzas, peer)] {
                for (id, element) in stanzas {
                    try harness.deliver(element, id: id, from: sender)
                    let error = try #require(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: id, type: "error")))
                    #expect(error.child(named: "error")?.child(named: "item-not-found", namespace: XMPPNamespaces.stanzas) != nil)
                }
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
            #expect(harness.eventCount { if case .jingleFileTransferProgress = $0 { true } else { false } } == 0)

            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }

        @Test
        func `A transport-replace reusing another session's IBB sid is rejected`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            let secondPeer = try #require(FullJID.parse("second@example.com/res"))
            try harness.receive(
                action: "session-initiate", sid: "sid-2",
                payload: [JingleInitiatorHarness.fileContent(JingleFileDescription(name: "other.txt", size: 3))], id: "initiate-2", from: secondPeer
            )

            try harness.receive(action: "transport-replace", sid: "sid-2", payload: [JingleInitiatorHarness.ibbContent()], id: "replace-2", from: secondPeer)
            let reject = try await harness.sentStanza { stanza in
                stanza.child(named: "jingle")?.attribute("action") == JingleAction.transportReject.rawValue
                    && stanza.child(named: "jingle")?.attribute("sid") == "sid-2"
            }
            #expect(reject != nil)

            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
        }

        @Test
        func `A checksum delivered before the last chunk still lets the close get a result`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness, file: JingleFileDescription(name: "test.txt", size: 6))
            let receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }

            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            let hash = JingleFileDescription.sha256Hash(of: [1, 2, 3, 4, 5, 6])
            try harness.receive(action: "session-info", sid: "sid-1", payload: [JingleInitiatorHarness.checksum(hash)])
            try harness.deliver(JingleInitiatorHarness.ibbData([4, 5, 6], seq: 1), id: "data-1")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "close", type: "result")) != nil)
            #expect(try await receive.value == [1, 2, 3, 4, 5, 6])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }
    }

    struct PeerEnds {
        @Test
        func `A short close fails as incomplete exactly once`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            await #expect(throws: JingleModule.JingleError.transportFailed("The transfer ended before the whole file arrived")) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", .incomplete) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "cancel") != nil)
        }

        @Test
        func `Data after a close gets item-not-found and is not taken in`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            try harness.deliver(JingleInitiatorHarness.ibbData([3], seq: 1), id: "data-1")
            let error = try #require(try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "data-1", type: "error")))
            #expect(error.child(named: "error")?.child(named: "item-not-found", namespace: XMPPNamespaces.stanzas) != nil)
            await #expect(throws: JingleModule.JingleError.transportFailed("The transfer ended before the whole file arrived")) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
        }

        @Test
        func `Partial data then a success terminate fails as incomplete exactly once`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2], seq: 0), id: "data-0")
            try harness.receive(action: "session-terminate", sid: "sid-1", payload: [JingleInitiatorHarness.reason("success")])

            await #expect(throws: JingleModule.JingleError.transportFailed("The transfer ended before the whole file arrived")) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", .incomplete) = $0 { true } else { false } } == 1)
            // The peer already ended the session, so nothing is sent back. The terminate this guards against would go
            // out from a detached task, so the count is read only after giving that task room to run — read straight
            // after the throw, the assertion holds whether or not the guard exists.
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue, timeout: .milliseconds(100)) == nil)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        @Test(arguments: [true, false])
        func `Full data without a close completes after the end-of-stream wait`(claimFirst: Bool) async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            try await startIBBReceive(harness)

            let receive: Task<[UInt8], any Error>
            if claimFirst {
                receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }
                try await Task.sleep(for: .milliseconds(50))
                try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            } else {
                try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
                receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }
            }

            #expect(try await receive.value == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            #expect(try await harness.sentJingle(action: JingleAction.sessionInfo.rawValue)?.child(named: "jingle")?.child(named: "received") != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "success") != nil)
        }

        @Test
        func `A local terminate on a claimed receive throws session not found and reports nothing`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            let receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }
            try await Task.sleep(for: .milliseconds(100))

            try await harness.module.terminateSession(sid: "sid-1", reason: .cancel)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await receive.value
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        @Test
        func `A close before the claim finalizes at the claim`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }

        @Test
        func `A success terminate with nothing buffered fails as incomplete at once`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.receive(action: "session-terminate", sid: "sid-1", payload: [JingleInitiatorHarness.reason("success")])

            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", .incomplete) = $0 { true } else { false } } == 1)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
        }
    }

    struct UnclaimedExpiry {
        @Test
        func `Data nobody claims fails as timed out and releases its buffer`() async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")

            let failure = try await harness.event { if case .jingleFileTransferFailed("sid-1", .timeout) = $0 { true } else { false } }
            #expect(failure != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "timeout") != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
        }
    }

    struct OutgoingStreamClose {
        @Test
        func `A peer closing the stream this side sends on fails as canceled`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await startIBBSend(harness)

            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, .cancel) = $0 { true } else { false } } != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
        }
    }

    struct ChecksumVerification {
        /// A content offering a 3-byte file whose `<file>` carries `extra` children.
        private static func offerContent(extra: [XMLElement]) -> XMLElement {
            var file = XMLElement(name: "file")
            file.setChildText(named: "name", to: "test.txt")
            file.setChildText(named: "size", to: "3")
            for child in extra {
                file.addChild(child)
            }
            var description = XMLElement(name: "description", namespace: XMPPNamespaces.jingleFileTransfer)
            description.addChild(file)
            var content = XMLElement(name: "content", attributes: ["creator": "initiator", "name": "a-file-offer"])
            content.addChild(description)
            content.addChild(SOCKS5Transport(sid: "transport-sid").toXML())
            return content
        }

        private static let hashUsed = XMLElement(name: "hash-used", namespace: XMPPNamespaces.hashes2, attributes: ["algo": "sha-256"])

        private static func deliverFullStream(_ harness: JingleInitiatorHarness, content: XMLElement) async throws {
            try harness.receive(action: "session-initiate", sid: "sid-1", payload: [content], id: "initiate")
            try await harness.module.acceptFileTransfer(sid: "sid-1")
            try harness.receive(action: "transport-replace", sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
        }

        private static let corrupted = JingleModule.JingleError.transportFailed("The received file is corrupted")

        @Test
        func `A session-info checksum mismatch fails as corrupted and reports nothing else`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.receive(action: "session-info", sid: "sid-1", payload: [JingleInitiatorHarness.checksum("wronghash==")])
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            await #expect(throws: Self.corrupted) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", .checksumMismatch) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        @Test
        func `An offer's hash is verified`() async throws {
            let harness = JingleInitiatorHarness()
            try await Self.deliverFullStream(harness, content: JingleInitiatorHarness.fileContent(JingleFileDescription(name: "test.txt", size: 3, hash: "wronghash==")))

            await #expect(throws: Self.corrupted) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
        }

        @Test
        func `A promised checksum arriving within the wait is verified`() async throws {
            let harness = JingleInitiatorHarness()
            try await Self.deliverFullStream(harness, content: Self.offerContent(extra: [Self.hashUsed]))
            let receive = Task { try await harness.module.receiveFileData(sid: "sid-1") }
            try await Task.sleep(for: .milliseconds(100))

            try harness.receive(action: "session-info", sid: "sid-1", payload: [JingleInitiatorHarness.checksum("wronghash==")])
            await #expect(throws: Self.corrupted) {
                _ = try await receive.value
            }
        }

        @Test
        func `A promised checksum that never arrives completes unverified`() async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            try await Self.deliverFullStream(harness, content: Self.offerContent(extra: [Self.hashUsed]))

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }

        @Test
        func `An offer hash in an unsupported algorithm completes unverified`() async throws {
            let harness = JingleInitiatorHarness()
            let file = JingleFileDescription(name: "test.txt", size: 3, hash: "wronghash==", hashAlgo: "sha-512")
            try await Self.deliverFullStream(harness, content: JingleInitiatorHarness.fileContent(file))

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
        }

        @Test
        func `An offer advertising range support is still verified against its checksum`() async throws {
            let harness = JingleInitiatorHarness()
            // An empty `<range/>` advertises support and stands for the whole file, so the checksum still applies.
            let file = JingleFileDescription(
                name: "test.txt", size: 3, hash: JingleFileDescription.sha256Hash(of: [1, 2, 3]), range: JingleFileRange()
            )
            try await startIBBReceive(harness, file: file)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
        }

        @Test
        func `An offer advertising range support still fails a checksum mismatch`() async throws {
            let harness = JingleInitiatorHarness()
            // The empty `<range/>` must not buy an exemption from verification: the bytes below do not match the hash.
            let file = JingleFileDescription(
                name: "test.txt", size: 3, hash: JingleFileDescription.sha256Hash(of: [9, 9, 9]), range: JingleFileRange()
            )
            try await startIBBReceive(harness, file: file)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            await #expect(throws: Self.corrupted) {
                _ = try await harness.module.receiveFileData(sid: "sid-1")
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        @Test
        func `IBB data before the transfer is accepted is refused instead of buffered`() async throws {
            let harness = JingleInitiatorHarness()
            try harness.receiveOffer(sid: "sid-1", file: JingleFileDescription(name: "test.txt", size: 3))
            try harness.receive(action: "transport-replace", sid: "sid-1", payload: [JingleInitiatorHarness.ibbContent()])
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")

            let reply = try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "data-0", type: "error"))
            #expect(reply?.child(named: "error")?.child(named: "unexpected-request") != nil)
            #expect(harness.eventCount { if case .jingleFileTransferProgress = $0 { true } else { false } } == 0)

            // The session goes with the refusal. Left alive, its offer would still be acceptable, and accepting it
            // would wait on a stream this side has already told the sender to stop.
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.acceptFileTransfer(sid: "sid-1")
            }
        }

        @Test
        func `The received notification names the content it acknowledges`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")
            _ = try await harness.module.receiveFileData(sid: "sid-1")

            let info = try await harness.sentJingle(action: JingleAction.sessionInfo.rawValue)
            let received = info?.child(named: "jingle")?.child(named: "received", namespace: XMPPNamespaces.jingleFileTransfer)
            #expect(received?.attribute("creator") == "initiator")
            #expect(received?.attribute("name") == "a-file-offer")
        }

        @Test
        func `More bytes than the offer declared fail the transfer`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3, 4], seq: 0), id: "data-0")

            #expect(try await harness.event { if case .jingleFileTransferFailed = $0 { true } else { false } } != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        /// XEP-0047 §2.2 answers a sequence number already consumed with `unexpected-request`, which is a different
        /// reply from the one a gap gets — collapsing the two would lose that distinction silently.
        @Test
        func `A repeated sequence number is answered unexpected-request`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbData([1], seq: 0), id: "data-repeat")

            let reply = try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "data-repeat", type: "error"))
            #expect(reply?.child(named: "error")?.child(named: "unexpected-request") != nil)
        }

        @Test
        func `A block whose payload is not base64 is answered bad-request`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            var data = XMLElement(name: "data", namespace: XMPPNamespaces.ibb, attributes: ["sid": "ibb-sid", "seq": "0"])
            data.addText("not base64!!")
            try harness.deliver(data, id: "data-bad")

            let reply = try await harness.sentStanza(matching: JingleInitiatorHarness.isReply(to: "data-bad", type: "error"))
            #expect(reply?.child(named: "error")?.child(named: "bad-request") != nil)
        }

        @Test
        func `An out-of-sequence block closes the stream instead of being acknowledged`() async throws {
            let harness = JingleInitiatorHarness()
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 7), id: "data-7")

            #expect(try await harness.sentIQ(matching: { $0.child(named: "close", namespace: XMPPNamespaces.ibb) != nil }) != nil)
            #expect(try await harness.event { if case .jingleFileTransferFailed = $0 { true } else { false } } != nil)
        }
    }

    struct SenderConfirmation {
        @Test
        func `A received confirmation arriving before the close's result still returns`() async throws {
            let gated = GatedCloseHarness()
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()

            let outcome = try await boundedOutcome { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to return, got \(String(describing: outcome))")
                return
            }
        }

        /// A harness whose IBB close is sent, then waits until the test answers it.
        private struct GatedCloseHarness {
            let harness: JingleInitiatorHarness
            let closeSent = AsyncSemaphore()
            let closeAnswered = AsyncSemaphore()

            init(timing: JingleTiming = JingleTiming()) {
                let closeSent = closeSent
                let closeAnswered = closeAnswered
                self.harness = JingleInitiatorHarness(timing: timing) { iq in
                    if iq.child(named: "close", namespace: XMPPNamespaces.ibb) != nil {
                        await closeSent.signal()
                        await closeAnswered.wait()
                    }
                    return nil
                }
            }
        }

        /// The confirmed branch of the sender's cleanup: the receiver acknowledges with `<received/>` and then never
        /// sends the terminate — a peer that crashes or drops between the two. Left uncovered, the session, its
        /// transport and its send record leak for the life of the connection, or the timer fires at a sid a later
        /// session has since taken.
        @Test
        func `A confirmed send terminates itself when the peer never does`() async throws {
            let gated = GatedCloseHarness(timing: .short)
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()
            _ = try await boundedOutcome { try await send.value }

            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "success") != nil)
        }

        @Test
        func `The receiver's terminate after its received confirmation completes the session once`() async throws {
            let gated = GatedCloseHarness()
            let harness = gated.harness
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }
            await gated.closeSent.wait()
            try harness.receive(action: "session-info", sid: sid, payload: [received])
            await gated.closeAnswered.signal()
            try await send.value

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            #expect(try await harness.event(matching: JingleInitiatorHarness.isCompletion) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test
        func `Without a confirmation the sender terminates with success after the wait`() async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            let sid = try await startIBBSend(harness)

            try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            let terminate = try #require(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue))
            #expect(terminate.child(named: "jingle")?.child(named: "reason")?.child(named: "success") != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        /// The receiver already holds every acknowledged block. A close it refuses, because it finished the stream on its
        /// own, leaves the send to its confirmation instead of failing a transfer that arrived.
        @Test
        func `A refused close after every block was acknowledged still completes on the receiver's terminate`() async throws {
            let harness = JingleInitiatorHarness { iq in
                if iq.child(named: "close", namespace: XMPPNamespaces.ibb) != nil {
                    throw JingleModule.JingleError.transportFailed("item-not-found")
                }
                return nil
            }
            let sid = try await startIBBSend(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }
            #expect(try await harness.sentIQ(matching: { $0.child(named: "close", namespace: XMPPNamespaces.ibb) != nil }) != nil)

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            let outcome = try await boundedOutcome { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to return, got \(String(describing: outcome))")
                return
            }
            #expect(try await harness.event(matching: JingleInitiatorHarness.isCompletion) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test
        func `A success terminate before the send starts fails as canceled`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await startIBBSend(harness)

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, .cancel) = $0 { true } else { false } } != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
        }

        @Test
        func `A receive whose terminate fails to send still reports exactly one event`() async throws {
            let harness = JingleInitiatorHarness(failingActions: [JingleAction.sessionTerminate.rawValue])
            try await startIBBReceive(harness)
            try harness.deliver(JingleInitiatorHarness.ibbData([1, 2, 3], seq: 0), id: "data-0")
            try harness.deliver(JingleInitiatorHarness.ibbClose(), id: "close")

            #expect(try await harness.module.receiveFileData(sid: "sid-1") == [1, 2, 3])
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }
    }
}
