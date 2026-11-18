import DuckoTestSupport
import Testing
@testable import DuckoXMPP

private func isTerminate(_ stanza: XMLElement, sid: String, reason: String) -> Bool {
    guard let jingle = stanza.child(named: "jingle"), jingle.attribute("action") == JingleAction.sessionTerminate.rawValue,
          jingle.attribute("sid") == sid else { return false }
    return jingle.child(named: "reason")?.child(named: reason) != nil
}

/// A peer's offer of a 3-byte file in session `sid` over a SOCKS5 transport without candidates.
private func offerXML(sid: String) -> String {
    """
    <iq type='set' id='offer-\(sid)' from='peer@example.com/res'>\
    <jingle xmlns='urn:xmpp:jingle:1' action='session-initiate' sid='\(sid)' initiator='peer@example.com/res'>\
    <content creator='initiator' name='a-file-offer'>\
    <description xmlns='urn:xmpp:jingle:apps:file-transfer:5'><file><name>test.txt</name><size>3</size></file></description>\
    <transport xmlns='urn:xmpp:jingle:transports:s5b:1' sid='transport-sid'/>\
    </content>\
    </jingle>\
    </iq>
    """
}

enum JingleShutdownTests {
    struct PreClose {
        @Test
        func `Ending the connection tells each session's peer it is gone and reports each session once`() async throws {
            let harness = JingleInitiatorHarness()
            let sentSID = try await harness.initiate()
            try harness.receiveOffer(sid: "offered")

            await harness.module.prepareForDisconnect()

            for sid in [sentSID, "offered"] {
                #expect(try await harness.sentStanza { isTerminate($0, sid: sid, reason: "gone") } != nil)
                #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .disconnected) = $0 { true } else { false } } == 1)
                await #expect(throws: JingleModule.JingleError.sessionNotFound) {
                    try await harness.module.awaitTransportReady(sid: sid)
                }
            }
            await harness.module.handleDisconnect()
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 2)
        }

        @Test
        func `No session starts once the connection is closing`() async throws {
            let harness = JingleInitiatorHarness()
            await harness.module.prepareForDisconnect()

            await #expect(throws: JingleModule.JingleError.notConnected) {
                _ = try await harness.initiate()
            }
            try harness.receiveOffer(sid: "late")
            #expect(try await harness.sentStanza { isTerminate($0, sid: "late", reason: "gone") } != nil)
            #expect(harness.receivedOffers().isEmpty)
        }

        @Test
        func `A disconnect says goodbye to every peer before announcing it is unavailable, even when one goodbye fails`() async throws {
            let mock = MockTransport()
            let client = XMPPClient(
                domain: "example.com", credentials: .init(username: "user", password: "pass"),
                transport: mock, requireTLS: false, allowsPLAIN: true
            )
            await client.register(JingleModule())
            let connect = Task { try await client.connect(host: "example.com", port: 5222) }
            await simulateNoTLSConnect(mock)
            try await connect.value

            for sid in ["sid-a", "sid-b"] {
                await mock.simulateReceive(offerXML(sid: sid))
                try await eventually {
                    await mock.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("offer-\(sid)") }
                }
            }
            await mock.failNextSend(matching: #"sid="sid-a""#, error: XMPPClientError.sendFailed("The connection was closed"))

            await disconnectFast(client)

            let sent = await sentElements(on: mock)
            let goodbye = sent.firstIndex { isTerminate($0, sid: "sid-b", reason: "gone") }
            let unavailable = sent.firstIndex { $0.name == "presence" && $0.attribute("type") == "unavailable" }
            let goodbyeIndex = try #require(goodbye)
            let unavailableIndex = try #require(unavailable)
            #expect(goodbyeIndex < unavailableIndex)
        }
    }

    struct SendWithoutTransport {
        private static let candidateError = JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))

        /// The IBB switch the peer has not accepted carries nothing yet, so a send that skips the transport wait is refused.
        /// Its session ends with it, so the owner's error comes with the session's failure event.
        @Test
        func `A send before the transport is ready is refused and ends the session`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            try harness.receive(action: JingleAction.transportInfo.rawValue, sid: sid, payload: [Self.candidateError])
            #expect(try await harness.sentJingle(action: JingleAction.transportReplace.rawValue) != nil)

            await #expect(throws: JingleModule.JingleError.transportFailed("No connection is open for the transfer")) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .failedTransport) = $0 { true } else { false } } == 1)
            #expect(try await harness.sentStanza { isTerminate($0, sid: sid, reason: "failed-transport") } != nil)
        }

        /// A connection the peer reached but never nominated is not written to: the refused send closes it with the session.
        @Test
        func `A send before the peer nominated the listener's connection is refused and closes that connection`() async throws {
            let harness = JingleInitiatorHarness()
            let sid = try await harness.initiate()
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid)
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            #expect(try await harness.sentJingle(action: JingleAction.transportInfo.rawValue) != nil)

            await #expect(throws: JingleModule.JingleError.transportFailed("No connection is open for the transfer")) {
                try await harness.module.sendFileData(sid: sid, data: [1, 2, 3])
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .failedTransport) = $0 { true } else { false } } == 1)
            let read = try await boundedOutcome { _ = try await peer.receive(1) }
            guard case .failure? = read else {
                Issue.record("Expected the unnominated connection to close unwritten, got \(String(describing: read))")
                return
            }
        }
    }

    /// Serialized because each transfer parks cooperative threads in blocking socket calls.
    @Suite(.serialized)
    struct PeerEndGrace {
        private static let grace = JingleTiming(peerEndGrace: .seconds(2))

        /// Offers a large file and connects to this side's listener as the peer, which then nominates that connection.
        private static func sendOffer(_ harness: JingleInitiatorHarness) async throws -> (sid: String, peer: SOCKS5Connection) {
            let file = JingleFileDescription(name: "big.bin", size: 16_000_000)
            let sid = try await harness.initiate(file: file)
            try harness.receive(action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [JingleInitiatorHarness.fileContent(file)])
            let peer = try await harness.connectToDirectCandidate(sid: sid)
            try harness.nominateDirectCandidate(sid: sid)
            try await harness.module.awaitTransportReady(sid: sid)
            return (sid, peer)
        }

        @Test
        func `A receive whose stream broke reports the reason the peer then gives`() async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            let peer = try await harness.acceptSOCKS5Offer(listener: harness.receiveSOCKS5Offer())
            let module = harness.module
            let receive = Task { try await module.receiveFileData(sid: "sid-1") }
            try await peer.send([1])
            await peer.close()
            // The short read is in and the receive waits for the peer's end.
            try await eventually { module.state.withLock { $0.resources["sid-1"]?.receive?.wake != nil } }

            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: "sid-1", payload: [JingleInitiatorHarness.reason("gone")])

            let outcome = try await boundedOutcome { _ = try await receive.value }
            guard case .failure? = outcome else {
                Issue.record("Expected the receive to fail, got \(String(describing: outcome))")
                return
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", _, .gone) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        /// Only a peer's failure takes over the end. A peer that calls a short stream a success is wrong about it, so the
        /// receive still fails as incomplete. The peer's terminate already ended the session, so nothing goes back.
        @Test
        func `A receive whose stream broke fails as incomplete when the peer then ends it as a success`() async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            let peer = try await harness.acceptSOCKS5Offer(listener: harness.receiveSOCKS5Offer())
            let module = harness.module
            let receive = Task { try await module.receiveFileData(sid: "sid-1") }
            try await peer.send([1])
            await peer.close()
            // The short read is in and the receive waits for the peer's end.
            try await eventually { module.state.withLock { $0.resources["sid-1"]?.receive?.wake != nil } }

            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: "sid-1", payload: [JingleInitiatorHarness.reason("success")])

            let outcome = try await boundedOutcome { _ = try await receive.value }
            guard case let .failure(error)? = outcome else {
                Issue.record("Expected the receive to fail, got \(String(describing: outcome))")
                return
            }
            #expect(error as? JingleModule.JingleError == .transportFailed(JingleTransferFailureReason.incomplete.displayText))
            #expect(harness.eventCount { if case .jingleFileTransferFailed("sid-1", _, .incomplete) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isCompletion) == 0)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }

        @Test
        func `A send whose write failed reports the reason the peer then gives`() async throws {
            let harness = JingleInitiatorHarness(timing: Self.grace)
            let (sid, peer) = try await Self.sendOffer(harness)
            let module = harness.module
            let send = Task { try await module.sendFileData(sid: sid, data: [UInt8](repeating: 7, count: 16_000_000)) }
            try await Task.sleep(for: .milliseconds(200))
            await peer.close()
            // The write failed and the send waits for the peer's end.
            try await eventually { module.state.withLock { $0.resources[sid]?.send?.wait != nil } }

            try harness.receive(action: JingleAction.sessionTerminate.rawValue, sid: sid, payload: [JingleInitiatorHarness.reason("cancel")])

            let outcome = try await boundedOutcome { try await send.value }
            guard case .failure? = outcome else {
                Issue.record("Expected the send to fail, got \(String(describing: outcome))")
                return
            }
            #expect(harness.eventCount { if case .jingleFileTransferFailed(sid, _, .cancel) = $0 { true } else { false } } == 1)
            #expect(harness.eventCount(matching: JingleInitiatorHarness.isFailure) == 1)
            #expect(harness.sentJingleCount(action: JingleAction.sessionTerminate.rawValue) == 0)
        }
    }
}
