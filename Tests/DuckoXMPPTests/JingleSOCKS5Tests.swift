import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private struct TestCandidate {
    let cid: String
    let host: String
    let port: UInt16
    let jid: String
    let priority: UInt32
    let type: String
}

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

/// Builds a session-initiate IQ XML with SOCKS5 transport candidates.
private func sessionInitiateWithCandidatesXML(
    id: String = "jingle-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid",
    candidates: [TestCandidate] = []
) -> String {
    let candidateXML = candidates.map { c in
        "<candidate cid='\(c.cid)' host='\(c.host)' port='\(c.port)' jid='\(c.jid)' priority='\(c.priority)' type='\(c.type)'/>"
    }.joined()
    return """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='\(from)'>\
    <content creator='initiator' name='a-file-offer'>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'>\
    <file>\
    <name>test.txt</name>\
    <size>1024</size>\
    </file>\
    </description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    \(candidateXML)\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-info IQ XML with candidate-used.
private func transportInfoCandidateUsedXML(
    id: String = "ti-1",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid",
    cid: String = "proxy-1"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    <candidate-used cid='\(cid)'/>\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

/// Builds a transport-info IQ XML with candidate-error.
private func transportInfoCandidateErrorXML(
    id: String = "ti-2",
    sid: String = "sid-123",
    from: String = "peer@example.com/res",
    transportSID: String = "transport-sid"
) -> String {
    """
    <iq type='set' id='\(id)' from='\(from)'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='transport-info' sid='\(sid)'>\
    <content creator='initiator' name='a-file-offer'>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='\(transportSID)'>\
    <candidate-error/>\
    </transport>\
    </content>\
    </jingle>\
    </iq>
    """
}

// MARK: - Tests

enum JingleSOCKS5Tests {
    struct TransportInfoCandidateUsed {
        @Test
        func `Handles transport-info with candidate-used`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session via session-initiate
            let initXML = sessionInitiateWithCandidatesXML(
                candidates: [TestCandidate(cid: "proxy-1", host: "proxy.example.com", port: 1080, jid: "proxy@example.com", priority: 10, type: "proxy")]
            )
            await mock.simulateReceive(initXML)
            try? await Task.sleep(for: .milliseconds(200))

            // Accept the session (as responder)
            let module = try #require(await client.module(ofType: JingleModule.self))
            try await module.acceptFileTransfer(sid: "sid-123")
            try? await Task.sleep(for: .milliseconds(100))

            // Now send transport-info with candidate-used from peer
            await mock.simulateReceive(transportInfoCandidateUsedXML(cid: "proxy-1"))
            try? await Task.sleep(for: .milliseconds(100))

            // Only the initiator activates a proxy, so the responder sends no activation when the peer reports a used candidate.
            let sent = await mock.sentBytes.map { String(decoding: $0, as: UTF8.self) }
            #expect(!sent.contains { $0.contains("<activate") })
            await disconnectFast(client)
        }
    }

    struct TransportInfoCandidateError {
        @Test
        func `A responder reports no failure for the initiator's candidate-error`() async throws {
            let mock = MockTransport()
            let client = try await makeConnectedClient(mock: mock)

            // Create session via session-initiate
            await mock.simulateReceive(sessionInitiateWithCandidatesXML())
            try? await Task.sleep(for: .milliseconds(200))

            let eventsTask = Task {
                try await collectEvents(from: client) { event in
                    if case .jingleFileTransferFailed = event { return true }
                    return false
                }
            }

            // The initiator's candidate-error leaves the outcome to what it sends next, here a session-terminate.
            await mock.simulateReceive(transportInfoCandidateErrorXML())
            await mock.simulateReceive(
                "<iq type='set' id='terminate-1' from='peer@example.com/res'><jingle xmlns='urn:xmpp:jingle:1' action='session-terminate' sid='sid-123'><reason><failed-transport/></reason></jingle></iq>"
            )

            let events = try await eventsTask.value
            guard case let .jingleFileTransferFailed(sid, reason) = events.last else {
                Issue.record("Expected jingleFileTransferFailed event")
                await disconnectFast(client)
                return
            }
            #expect(sid == "sid-123")
            #expect(reason == .failedTransport)

            await disconnectFast(client)
        }
    }

    struct InitiatorSOCKS5Outcomes {
        private static let proxyJID = "proxy.example.com"

        /// Answers proxy discovery with one Proxy65 service whose activation fails.
        private static func answerWithFailingProxy(_ iq: XMLElement) throws -> XMLElement? {
            guard let query = iq.child(named: "query") else { return nil }
            var answer = XMLElement(name: "query", namespace: query.namespace)
            switch query.namespace {
            case XMPPNamespaces.discoItems:
                answer.addChild(XMLElement(name: "item", attributes: ["jid": proxyJID]))
            case XMPPNamespaces.discoInfo:
                answer.addChild(XMLElement(name: "feature", attributes: ["var": XMPPNamespaces.bytestreams]))
            case XMPPNamespaces.bytestreams:
                if query.child(named: "activate") != nil {
                    throw XMPPStanzaError(errorType: .cancel, condition: .itemNotFound)
                }
                answer.addChild(XMLElement(name: "streamhost", attributes: ["jid": proxyJID, "host": "192.0.2.1", "port": "7777"]))
            default:
                return nil
            }
            return answer
        }

        private static func candidateError() -> XMLElement {
            JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))
        }

        private static func isActivation(_ iq: XMLElement) -> Bool {
            iq.child(named: "query")?.child(named: "activate") != nil
        }

        /// Starts a session whose SOCKS5 attempt is inside this side's listener accept, proven by a probe that holds a
        /// handshake open.
        private static func startAttempt(_ harness: JingleInitiatorHarness) async throws -> (sid: String, probe: SOCKS5GreetingProbe) {
            let sid = try await harness.initiate()
            let direct = try harness.offeredCandidate(type: "direct")
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let probe = try #require(SOCKS5GreetingProbe(candidate: direct))
            try #require(probe.awaitReply())
            return (sid, probe)
        }

        @Test
        func `An initiator reports its SOCKS5 failure while the attempt is current`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            let direct = try harness.offeredCandidate(type: "direct")
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)

            // A handshake naming another stream fails this side's accept, which ends the attempt as a failure.
            let host = try #require(direct.attribute("host"))
            let port = try #require(direct.attribute("port").flatMap(UInt16.init))
            let stranger = SOCKS5Connection()
            _ = try? await stranger.connect(host: host, port: port, destinationAddress: "another-stream", timeout: 2)
            let report = try await harness.sentJingle(action: JingleAction.transportInfo.rawValue)
            #expect(report?.child(named: "jingle")?.child(named: "content")?.child(named: "transport")?.child(named: "candidate-error") != nil)
            await stranger.close()
        }

        @Test
        func `An initiator ignores its SOCKS5 failure after switching to IBB`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, probe) = try await Self.startAttempt(harness)

            // The peer's candidate-error switches this side to IBB and closes the listener its attempt waits on.
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue, timeout: .seconds(1)) == nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `A repeated session-accept does not start a second SOCKS5 attempt`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, probe) = try await Self.startAttempt(harness)

            // A second attempt would find the listener busy and report a failure while the first one still runs.
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue, timeout: .seconds(1)) == nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `A repeated candidate-error proposes IBB only once`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            try await Task.sleep(for: .milliseconds(300))
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 1)
        }

        @Test
        func `An unusable proxy tells the peer and falls back to IBB`() async throws {
            // The advertised proxy is unroutable, so the dial fails; the bounded proxy wait is what keeps that prompt.
            let harness = JingleInitiatorHarness(
                timing: JingleTiming(proxyConnectWait: .milliseconds(50)), answerIQ: Self.answerWithFailingProxy
            )
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy"))])

            // XEP-0260 §2.4: say the proxy is unusable, then offer another transport rather than ending the transfer.
            let info = try await harness.sentStanza(matching: { stanza in
                stanza.child(named: "jingle")?.attribute("action") == JingleAction.transportInfo.rawValue
                    && stanza.child(named: "jingle")?.child(named: "content")?.child(named: "transport")?.child(named: "proxy-error") != nil
            })
            #expect(info != nil)
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            #expect(harness.eventCount { if case .jingleFileTransferFailed = $0 { true } else { false } } == 0)
            // Nothing is activated, because this side never reached a proxy to activate: announcing otherwise would
            // point the peer at a bytestream no connection backs.
            #expect(try await harness.sentIQ(timeout: .milliseconds(100), matching: Self.isActivation) == nil)
        }

        @Test
        func `An abandoned session accepts no further actions`() async throws {
            // The proxy fails and the IBB fallback cannot be sent either, so the session really is abandoned.
            let harness = JingleInitiatorHarness(
                timing: JingleTiming(proxyConnectWait: .milliseconds(50)),
                failingActions: [JingleAction.transportReplace.rawValue], answerIQ: Self.answerWithFailingProxy
            )
            let sid = try await harness.initiate()
            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue) != nil)

            // A send finishing now can't end the session as a success.
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await harness.module.terminateSession(sid: sid, reason: .success)
            }
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 1)
        }

        @Test
        func `Abandoning a transport closes its listener`() async throws {
            let harness = JingleInitiatorHarness(
                timing: JingleTiming(proxyConnectWait: .milliseconds(50)), answerIQ: Self.answerWithFailingProxy
            )
            let (sid, probe) = try await Self.startAttempt(harness)

            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            // Closing the listener ends the handshake the probe holds open.
            #expect(probe.awaitClosed())
        }

        @Test
        func `A proxy candidate used after switching to IBB is not activated`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithFailingProxy)
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy"))])

            let activation = try await harness.sentIQ(timeout: .seconds(1), matching: Self.isActivation)
            #expect(activation == nil)
            let failure = try await harness.event(timeout: .milliseconds(100)) { event in
                if case .jingleFileTransferFailed = event { return true }
                return false
            }
            #expect(failure == nil)
        }

        @Test
        func `A proxy failure that lands after switching to IBB leaves the fallback in place`() async throws {
            // The dial is given long enough to still be running when the peer's candidate-error switches to IBB, so its
            // failure arrives afterwards — the case where a stale proxy outcome could tear down a settled fallback.
            let harness = JingleInitiatorHarness(
                timing: JingleTiming(proxyConnectWait: .seconds(1)), answerIQ: Self.answerWithFailingProxy
            )
            let sid = try await harness.initiate()

            try harness.receive(action: "transport-info", sid: sid, payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy"))])
            // Armed before the candidate-error lands. The dial has to still be running, or this exercises the reverse
            // ordering, where the failure switches to IBB first and every assertion below holds for the wrong reason.
            // Whether the dial blocks depends on the network, so it is asserted rather than assumed. A host that answers
            // or refuses TEST-NET-1 immediately fails here instead of passing green.
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue, timeout: .milliseconds(50)) == nil)
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 0)

            try harness.receive(action: "transport-info", sid: sid, payload: [Self.candidateError()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            let failure = try await harness.event(timeout: .seconds(2)) { event in
                if case .jingleFileTransferFailed = event { return true }
                return false
            }
            #expect(failure == nil)
            #expect(try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue, timeout: .milliseconds(100)) == nil)
            // The late proxy failure must not propose a second fallback on top of the one already in place.
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 1)
        }
    }

    /// Serialized because each transfer parks cooperative threads in blocking socket calls (the listener's accept, the peer's
    /// handshake, this side's read or write); run in parallel they starve the pool that every other test needs.
    @Suite(.serialized)
    struct DirectListenerTransfers {
        private static let incomplete = JingleModule.JingleError.transportFailed("The transfer ended before the whole file arrived")

        /// Offers a large file to the peer and connects to this side's direct listener as the peer, once the peer accepted it,
        /// then nominates that connection as the peer's candidate-used would.
        private static func connect(_ harness: JingleInitiatorHarness) async throws -> (sid: String, peer: SOCKS5Connection) {
            let file = JingleFileDescription(name: "big.bin", size: 16_000_000)
            let sid = try await harness.initiate(file: file)
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.fileContent(file)])
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            try harness.nominateDirectCandidate(sid: sid)
            try await harness.module.awaitTransportReady(sid: sid)
            return (sid, peer)
        }

        /// Accepts the peer's offer of a 3-byte file and waits until this side connected to the peer's direct candidate, a
        /// listener the test runs.
        private static func accept(
            _ harness: JingleInitiatorHarness, cid: String = "peer-direct"
        ) async throws -> (sid: String, peer: SOCKS5Connection) {
            let listener = SOCKS5Listener()
            let port = try await listener.start()
            let peerJID = JingleInitiatorHarness.peer.description
            let candidate = SOCKS5Transport.Candidate(cid: cid, host: "127.0.0.1", port: port, jid: peerJID, priority: 100, type: .direct)
            let content = JingleContent(
                name: "a-file-offer", creator: "initiator", description: JingleFileDescription(name: "test.txt", size: 3),
                transport: .socks5(SOCKS5Transport(sid: "transport-sid", candidates: [candidate]))
            )
            try harness.receive(action: JingleAction.sessionInitiate.rawValue, sid: "sid-1", payload: [content.toXML()])
            try await harness.module.acceptFileTransfer(sid: "sid-1")

            let destination = SOCKS5Connection.destinationAddress(sid: "transport-sid", initiatorJID: peerJID, targetJID: "user@example.com/res")
            let peer = try await listener.accept(expectedDstAddr: destination)
            await listener.close()
            try await harness.module.awaitTransportReady(sid: "sid-1")
            return ("sid-1", peer)
        }

        /// This side dials none of the responder's candidates, and XEP-0260 §2.3 has it say so even when the responder
        /// reached its listener, since a responder can wait for both sides' reports before using the stream.
        @Test
        func `An initiator reached on its listener reports it used none of the peer's candidates`() async throws {
            let harness = JingleInitiatorHarness()
            let (_, peer) = try await Self.connect(harness)

            let report = try await harness.sentStanza { stanza in
                stanza.child(named: "jingle")?.attribute("action") == JingleAction.transportInfo.rawValue
            }
            let transport = report?.child(named: "jingle")?.child(named: "content")?.child(named: "transport")
            #expect(transport?.child(named: "candidate-error") != nil)
            #expect(transport?.child(named: "candidate-used") == nil)
            withExtendedLifetime(peer) {}
        }

        /// An initiator reports candidate-error even when this side's connection works, since it dials none of this side's
        /// candidates. Only the initiator decides a fallback, so the working stream stays and carries the file.
        @Test
        func `A responder keeps its connected stream after the initiator's candidate-error`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.accept(harness)

            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )
            try await peer.send([1, 2, 3])

            // Bounded: a responder that dropped its stream would wait for bytes that never come.
            let module = harness.module
            let received = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
            let outcome = try await boundedOutcome(timeout: .seconds(5)) {
                let data = try await module.receiveFileData(sid: sid)
                received.withLock { $0 = data }
            }
            #expect(outcome != nil)
            #expect(received.withLock { $0 } == [1, 2, 3])
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 0)
            withExtendedLifetime(peer) {}
        }

        /// The peer's candidate-used nominated this side's listener, which outweighs a later candidate-error or
        /// proxy-error (XEP-0260 §2.4), so the connection keeps carrying the file.
        @Test(arguments: ["candidate-error", "proxy-error"])
        func `An initiator keeps a nominated stream after the peer reports a SOCKS5 error`(report: String) async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            let (sid, peer) = try await Self.connect(harness)

            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: report))]
            )
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [1, 2, 3]) }

            // Bounded: an initiator that dropped its stream would leave the peer waiting for bytes that never come.
            #expect(try await Self.read(3, from: peer) == [1, 2, 3])
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 0)
            _ = try await boundedOutcome { try await send.value }
            withExtendedLifetime(peer) {}
        }

        /// A connection the peer made to this side's listener but never nominated is not the transport: when the peer
        /// reports a SOCKS5 error both sides have failed (XEP-0260 §2.4), so this side switches to IBB before writing any
        /// byte to that socket.
        @Test(arguments: ["candidate-error", "proxy-error"])
        func `An initiator falls back to IBB when the peer reports an error for a connection it never nominated`(report: String) async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            // Armed: this side's own report goes out once its listener accepted the peer's connection.
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)

            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: report))]
            )
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)
            // The unnominated socket is closed rather than written to.
            let read = try await boundedOutcome { _ = try await peer.receive(1) }
            guard case .failure? = read else {
                Issue.record("Expected the unnominated connection to close, got \(String(describing: read))")
                return
            }

            try harness.receive(
                action: JingleAction.transportAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()], id: "expected-accept"
            )
            try await harness.module.awaitTransportReady(sid: sid)
            try await harness.expectSingleReply(to: "expected-accept", type: "result", sid: sid)
            try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            #expect(try await harness.sentIQ { $0.child(named: "data", namespace: XMPPNamespaces.ibb) != nil } != nil)
        }

        /// The listener's accept and the peer's nomination can land in either order; the sender goes ahead only once both
        /// are in, and a send tried before then is refused rather than written to an unchosen socket.
        @Test(arguments: [true, false])
        func `A sender waits for the peer to nominate the connection its listener accepted`(nominateFirst: Bool) async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let module = harness.module
            let wait = Task { try await module.awaitTransportReady(sid: sid) }
            if nominateFirst {
                try harness.nominateDirectCandidate(sid: sid)
            }
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)

            if !nominateFirst {
                // Armed: the listener accepted the connection, yet nothing may use it before the nomination.
                let early = try await boundedOutcome(timeout: .milliseconds(200)) { try await wait.value }
                #expect(early == nil)
                await #expect(throws: JingleModule.JingleError.transportFailed("No connection is open for the transfer")) {
                    try await module.sendFileData(sid: sid, data: [1, 2, 3])
                }
                try harness.nominateDirectCandidate(sid: sid)
            }
            let ready = try await boundedOutcome { try await wait.value }
            guard case .success? = ready else {
                Issue.record("Expected the wait to resolve once nominated, got \(String(describing: ready))")
                return
            }

            let send = Task { try await module.sendFileData(sid: sid, data: [1, 2, 3]) }
            #expect(try await Self.read(3, from: peer) == [1, 2, 3])
            _ = try await boundedOutcome { try await send.value }
        }

        /// Only a replace this side proposed can be accepted. An unrequested transport-accept is answered out of order and
        /// leaves the connection in use carrying the file.
        @Test
        func `An unrequested transport-accept is refused and leaves the connection in use`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let (sid, peer) = try await Self.connect(harness)

            try harness.receive(
                action: JingleAction.transportAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.ibbContent()], id: "unrequested-accept"
            )
            try await harness.expectSingleOutOfOrderError(to: "unrequested-accept", sid: sid)

            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [1, 2, 3]) }
            #expect(try await Self.read(3, from: peer) == [1, 2, 3])
            _ = try await boundedOutcome { try await send.value }
        }

        /// A peer that stops reading partway through a write would otherwise hold the send, and the thread its write
        /// blocks, for as long as it likes. The session ends with it, so the peer is not left waiting for the rest.
        @Test
        func `A send the peer stops reading fails once the stall wait elapses and ends the session`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(sendStallWait: .milliseconds(300)))
            let (sid, peer) = try await Self.connect(harness)

            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 16_000_000)) }
            // Read a prefix that ends mid-chunk, so the stall lands where only part of the next write fits.
            _ = try await Self.read(3000, from: peer)
            let outcome = try await boundedOutcome(timeout: .seconds(10)) { try await send.value }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the stalled send to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .transportFailed("The other side stopped receiving the file"))
            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, .incomplete) = $0 { true } else { false } } != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "failed-transport") != nil)
            await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                try await module.awaitTransportReady(sid: sid)
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
        }

        /// A peer that stops sending partway through the file would otherwise hold the receive for as long as it likes.
        @Test
        func `A receive the peer stops sending fails as incomplete once the stall wait elapses`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(receiveStallWait: .milliseconds(300)))
            let (sid, peer) = try await Self.accept(harness)
            try await peer.send([1])

            let module = harness.module
            let outcome = try await boundedOutcome(timeout: .seconds(10)) { _ = try await module.receiveFileData(sid: sid) }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the stalled receive to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == Self.incomplete)
            withExtendedLifetime(peer) {}
        }

        /// A connection the peer made but never nominated is closed with the session, rather than left open with nothing
        /// to close it.
        @Test
        func `A connection the peer never nominated closes when the send times out`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(transportReadyWait: .milliseconds(500)))
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            // Armed: this side's own report goes out once its listener accepted, and parked, the peer's connection.
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)

            #expect(try await harness.event { if case .jingleFileTransferFailed(sid, .timeout) = $0 { true } else { false } } != nil)
            let read = try await boundedOutcome { _ = try await peer.receive(1) }
            guard case .failure? = read else {
                Issue.record("Expected the parked connection to close, got \(String(describing: read))")
                return
            }
        }

        /// The peer reached this side's listener but nominated the proxy, so the file goes over the proxy and the direct
        /// connection nobody chose is closed.
        @Test
        func `Choosing the proxy closes the direct connection the peer never nominated`() async throws {
            let proxy = SOCKS5Listener()
            let port = try await proxy.start()
            let proxyJID = "proxy.example.com"
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300))) { iq in
                guard let query = iq.child(named: "query") else { return nil }
                var answer = XMLElement(name: "query", namespace: query.namespace)
                switch query.namespace {
                case XMPPNamespaces.discoItems:
                    answer.addChild(XMLElement(name: "item", attributes: ["jid": proxyJID]))
                case XMPPNamespaces.discoInfo:
                    answer.addChild(XMLElement(name: "feature", attributes: ["var": XMPPNamespaces.bytestreams]))
                case XMPPNamespaces.bytestreams:
                    guard query.child(named: "activate") == nil else { return nil }
                    answer.addChild(XMLElement(name: "streamhost", attributes: ["jid": proxyJID, "host": "127.0.0.1", "port": String(port)]))
                default:
                    return nil
                }
                return answer
            }
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let direct = try await harness.connectToDirectCandidate(sid: sid)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)

            let transportSID = try #require(harness.offeredContent(sid: sid)?.child(named: "transport")?.attribute("sid"))
            let destination = SOCKS5Connection.destinationAddress(
                sid: transportSID, initiatorJID: "user@example.com/res", targetJID: JingleInitiatorHarness.peer.description
            )
            let relayed = Task { try await proxy.accept(expectedDstAddr: destination) }
            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.candidateUsed(harness.offeredCandidate(type: "proxy", sid: sid))]
            )
            let relay = try await relayed.value
            try await harness.module.awaitTransportReady(sid: sid)

            let read = try await boundedOutcome { _ = try await direct.receive(1) }
            guard case .failure? = read else {
                Issue.record("Expected the unchosen direct connection to close, got \(String(describing: read))")
                return
            }
            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [1, 2, 3]) }
            #expect(try await Self.read(3, from: relay) == [1, 2, 3])
            _ = try await boundedOutcome { try await send.value }
            await proxy.close()
        }

        /// Reads `count` bytes from `connection`, or nothing when they do not arrive within the bound.
        private static func read(_ count: Int, from connection: SOCKS5Connection) async throws -> [UInt8]? {
            let received = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
            _ = try await boundedOutcome {
                let data = try await connection.receive(count)
                received.withLock { $0 = data }
            }
            return received.withLock { $0 }
        }

        /// The initiator chooses candidate ids, so one can equal any name this side uses internally. A responder reports
        /// the candidate it connected to whatever its id.
        @Test
        func `A responder reports the candidate it used whatever the candidate's id`() async throws {
            let harness = JingleInitiatorHarness()
            let (_, peer) = try await Self.accept(harness, cid: "direct-listener")

            let report = try await harness.sentStanza { stanza in
                stanza.child(named: "jingle")?.attribute("action") == JingleAction.transportInfo.rawValue
            }
            let used = report?.child(named: "jingle")?.child(named: "content")?.child(named: "transport")?.child(named: "candidate-used")
            #expect(used?.attribute("cid") == "direct-listener")
            withExtendedLifetime(peer) {}
        }

        @Test
        func `A received file completes once every byte arrived`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.accept(harness)

            try await peer.send([1, 2, 3])
            #expect(try await harness.module.receiveFileData(sid: sid) == [1, 2, 3])
            #expect(harness.eventCount { if case .jingleFileTransferCompleted(sid, .socks5) = $0 { true } else { false } } == 1)
            #expect(try await harness.sentJingle(action: JingleAction.sessionInfo.rawValue)?.child(named: "jingle")?.child(named: "received") != nil)
            let terminate = try await harness.sentJingle(action: JingleAction.sessionTerminate.rawValue)
            #expect(terminate?.child(named: "jingle")?.child(named: "reason")?.child(named: "success") != nil)
            withExtendedLifetime(peer) {}
        }

        @Test
        func `A success terminate before the last bytes still completes`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.accept(harness)
            try await peer.send([1, 2])
            let receive = Task { try await harness.module.receiveFileData(sid: sid) }
            try await Task.sleep(for: .milliseconds(100))

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            try await peer.send([3])
            #expect(try await receive.value == [1, 2, 3])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 1)
            // The peer already ended the session, so this side sends no terminate back.
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        @Test
        func `A short EOF fails as incomplete`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.accept(harness)
            try await peer.send([1, 2])
            await peer.close()

            await #expect(throws: Self.incomplete) {
                _ = try await harness.module.receiveFileData(sid: sid)
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, .incomplete) = $0 { true } else { false } } == 1)
        }

        @Test
        func `A stall past the end-of-stream wait fails as incomplete`() async throws {
            let harness = JingleInitiatorHarness(timing: .short)
            let (sid, peer) = try await Self.accept(harness)
            try await peer.send([1, 2])
            let receive = Task { try await harness.module.receiveFileData(sid: sid) }
            try await Task.sleep(for: .milliseconds(50))

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            await #expect(throws: Self.incomplete) {
                _ = try await receive.value
            }
            withExtendedLifetime(peer) {}
        }

        @Test
        func `A success terminate before the claim with a stalled socket fails as incomplete after the wait`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(endOfStreamWait: .milliseconds(300), unclaimedReceiveExpiry: .seconds(30)))
            let (sid, peer) = try await Self.accept(harness)
            try await peer.send([1, 2])
            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])

            let start = ContinuousClock.now
            await #expect(throws: Self.incomplete) {
                _ = try await harness.module.receiveFileData(sid: sid)
            }
            let elapsed = ContinuousClock.now - start
            #expect(elapsed >= .milliseconds(250))
            // Bounded above as well: the 30 s unclaimed expiry this test deliberately set alongside the 300 ms
            // end-of-stream wait satisfies the lower bound just as well, so only a ceiling tells the two apart.
            #expect(elapsed < .seconds(5))
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, .incomplete) = $0 { true } else { false } } == 1)
            withExtendedLifetime(peer) {}
        }

        @Test
        func `A success terminate mid-write leaves the session up until the send commits it`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.connect(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 16_000_000)) }
            try await Task.sleep(for: .milliseconds(200))

            try harness.receive(action: "session-terminate", sid: sid, payload: [JingleInitiatorHarness.reason("success")])
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
            await peer.close()

            let outcome = try await boundedOutcome(timeout: .seconds(5)) { try await send.value }
            guard case .success? = outcome else {
                Issue.record("Expected the send to return, got \(String(describing: outcome))")
                return
            }
            #expect(harness.eventCount { if case .jingleFileTransferCompleted(sid, .socks5) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 0)
        }

        @Test
        func `A write that fails without a confirmation throws`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.connect(harness)
            let send = Task { try await harness.module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 16_000_000)) }
            try await Task.sleep(for: .milliseconds(200))

            await peer.close()
            let outcome = try await boundedOutcome(timeout: .seconds(5)) { try await send.value }
            guard case .failure? = outcome else {
                Issue.record("Expected the send to throw, got \(String(describing: outcome))")
                return
            }
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
        }

        @Test
        func `A transport-replace after the connection opened is rejected`() async throws {
            let harness = JingleInitiatorHarness()
            let (sid, peer) = try await Self.accept(harness)

            try harness.receive(action: "transport-replace", sid: sid, payload: [JingleInitiatorHarness.ibbContent()])
            #expect(try await harness.sentJingle(action: JingleAction.transportReject.rawValue) != nil)
            #expect(harness.sentJingleCount(action: JingleAction.transportAccept.rawValue) == 0)

            try await peer.send([1, 2, 3])
            #expect(try await harness.module.receiveFileData(sid: sid) == [1, 2, 3])
        }
    }

    struct ProxyActivationIQ {
        @Test
        func `Proxy activation IQ has correct structure`() {
            var query = XMLElement(name: "query", namespace: XMPPNamespaces.bytestreams, attributes: ["sid": "transport-sid"])
            var activate = XMLElement(name: "activate")
            activate.addText("target@example.com/res")
            query.addChild(activate)

            #expect(query.namespace == XMPPNamespaces.bytestreams)
            #expect(query.attribute("sid") == "transport-sid")

            let activateChild = query.child(named: "activate")
            #expect(activateChild != nil)
            #expect(activateChild?.textContent == "target@example.com/res")
        }
    }

    struct TransportState {
        @Test
        func `TransportState.pending is default`() throws {
            let bareJID = try #require(BareJID(localPart: "user", domainPart: "example.com"))
            let peer = try #require(FullJID(bareJID: bareJID, resourcePart: "res"))
            let desc = JingleFileDescription(name: "f.txt", size: 100)
            let transport = JingleTransportDescription.socks5(SOCKS5Transport(sid: "t-1"))
            let content = JingleContent(name: "offer", creator: "initiator", description: desc, transport: transport)
            let session = JingleSession(peer: peer, role: .initiator, content: content)

            if case .pending = session.transportState {
                // Expected
            } else {
                Issue.record("Expected .pending transport state")
            }
        }
    }
}
