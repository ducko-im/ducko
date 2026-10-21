import DuckoTestSupport
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

enum JingleCandidateNominationTests {
    struct Nomination {
        private static func candidate(_ cid: String, priority: UInt32) -> SOCKS5Transport.Candidate {
            SOCKS5Transport.Candidate(cid: cid, host: "192.0.2.1", port: 1080, jid: "peer@example.com/res", priority: priority, type: .direct)
        }

        private static let low = JingleModule.CandidateReport.used(candidate("low", priority: 100))
        private static let high = JingleModule.CandidateReport.used(candidate("high", priority: 200))
        private static let alsoLow = JingleModule.CandidateReport.used(candidate("also-low", priority: 100))

        /// The settled side and cid, `neither`, or `nil` while undecided.
        private static func describe(_ outcome: JingleModule.CandidateNomination.Outcome?) -> String? {
            switch outcome {
            case let .own(candidate)?: "own \(candidate.cid)"
            case let .peer(candidate)?: "peer \(candidate.cid)"
            case .neither?: "neither"
            case nil: nil
            }
        }

        /// One side's report against the peer's, and the outcome they settle.
        struct Reports: Sendable {
            let own: JingleModule.CandidateReport?
            let peer: JingleModule.CandidateReport
            var isDialing = true
            let expected: String?
        }

        /// XEP-0260 §2.4: a candidate-used beats a candidate-error, the higher priority wins between two, the initiator's
        /// choice wins a tie, and two errors leave neither. A peer report waits for this side's own while it dials, and
        /// decides alone before the dial starts.
        @Test(arguments: [
            Reports(own: high, peer: low, expected: "own high"),
            Reports(own: low, peer: high, expected: "peer high"),
            Reports(own: low, peer: alsoLow, expected: "own low"),
            Reports(own: low, peer: .error, expected: "own low"),
            Reports(own: .error, peer: low, expected: "peer low"),
            Reports(own: .error, peer: .error, expected: "neither"),
            Reports(own: nil, peer: low, expected: nil),
            Reports(own: nil, peer: low, isDialing: false, expected: "peer low")
        ])
        func `The nomination follows the priority rules`(reports: Reports) {
            let nomination = JingleModule.CandidateNomination(isDialing: reports.isDialing, own: reports.own, peer: reports.peer)
            #expect(Self.describe(nomination.outcome) == reports.expected)
        }

        struct Dial: Sendable {
            let peer: JingleModule.CandidateReport?
            let priority: UInt32
            let canWin: Bool
        }

        /// XEP-0260 §2.3: a dial stops at a candidate that would lose to the one the peer used.
        @Test(arguments: [
            Dial(peer: nil, priority: 100, canWin: true),
            Dial(peer: .error, priority: 100, canWin: true),
            Dial(peer: high, priority: 100, canWin: false),
            Dial(peer: high, priority: 200, canWin: true),
            Dial(peer: high, priority: 300, canWin: true)
        ])
        func `A candidate can still win unless the peer used one of higher priority`(dial: Dial) {
            let nomination = JingleModule.CandidateNomination(isDialing: true, peer: dial.peer)
            #expect(nomination.canWin(Self.candidate("dialed", priority: dial.priority)) == dial.canWin)
        }
    }

    /// Serialized because each transfer parks cooperative threads in blocking socket calls.
    @Suite(.serialized)
    struct InitiatorDial {
        private static let proxyJID = "proxy.example.com"

        /// Answers proxy discovery with one Proxy65 service.
        private static func answerWithProxy(_ iq: XMLElement) -> XMLElement? {
            guard let query = iq.child(named: "query") else { return nil }
            var answer = XMLElement(name: "query", namespace: query.namespace)
            switch query.namespace {
            case XMPPNamespaces.discoItems:
                answer.addChild(XMLElement(name: "item", attributes: ["jid": proxyJID]))
            case XMPPNamespaces.discoInfo:
                answer.addChild(XMLElement(name: "feature", attributes: ["var": XMPPNamespaces.bytestreams]))
            case XMPPNamespaces.bytestreams:
                answer.addChild(XMLElement(name: "streamhost", attributes: ["jid": proxyJID, "host": "192.0.2.1", "port": "7777"]))
            default:
                return nil
            }
            return answer
        }

        /// XEP-0260 §2.2: (2^16) × type preference (direct 126, proxy 10) + a local preference ranking one type's candidates.
        @Test
        func `Offered candidate priorities follow the type preferences`() async throws {
            let harness = JingleInitiatorHarness(answerIQ: Self.answerWithProxy)
            _ = try await harness.initiate()

            let candidates = harness.offeredCandidates()
            let direct = candidates.filter { $0.attribute("type") == "direct" }.compactMap { $0.attribute("priority").flatMap(UInt32.init) }
            let proxy = candidates.filter { $0.attribute("type") == "proxy" }.compactMap { $0.attribute("priority").flatMap(UInt32.init) }
            #expect(!direct.isEmpty)
            #expect(direct == direct.indices.map { 126 * 65536 + 65535 - UInt32($0) })
            #expect(proxy == [10 * 65536 + 65535])
        }

        /// The DST.ADDR for dialing a candidate the responder offered in session `sid`, which hashes the responder's JID
        /// before this side's (XEP-0260 §2.2).
        private static func responderDestination(_ harness: JingleInitiatorHarness, sid: String) throws -> String {
            let transportSID = try #require(harness.offeredContent(sid: sid)?.child(named: "transport")?.attribute("sid"))
            return SOCKS5Connection.destinationAddress(
                sid: transportSID, initiatorJID: JingleInitiatorHarness.peer.description, targetJID: "user@example.com/res"
            )
        }

        /// Matches this side's candidate-used naming `cid`.
        private static func isCandidateUsed(_ cid: String) -> @Sendable (XMLElement) -> Bool {
            { $0.child(named: "jingle")?.child(named: "content")?.child(named: "transport")?.child(named: "candidate-used")?.attribute("cid") == cid }
        }

        /// Sends three bytes over the session's transport and returns what `peer` receives of them.
        private static func transfer(on module: JingleModule, sid: String, to peer: SOCKS5Connection) async throws -> [UInt8]? {
            let send = Task { try await module.sendFileData(sid: sid, data: [1, 2, 3]) }
            let received = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
            _ = try await boundedOutcome {
                let data = try await peer.receive(3)
                received.withLock { $0 = data }
            }
            _ = try await boundedOutcome { try await send.value }
            return received.withLock { $0 }
        }

        /// This side reaches the responder's candidate and the responder reaches none of this side's, so the file goes over
        /// the dialed connection. The dial uses the responder-first DST.ADDR, and this side's candidate-used wins over the
        /// peer's candidate-error (XEP-0260 §2.4).
        @Test
        func `An initiator sends over the responder's candidate it reached`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            let responder = SOCKS5Listener()
            let port = try await responder.start()
            let destination = try Self.responderDestination(harness, sid: sid)
            let accepted = Task { try await responder.accept(expectedDstAddr: destination, timeout: 5) }
            let candidate = SOCKS5Transport.Candidate(
                cid: "responder-direct", host: "127.0.0.1", port: port, jid: JingleInitiatorHarness.peer.description,
                priority: 100, type: .direct
            )

            try harness.receive(
                action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [harness.acceptedContent(sid: sid, candidates: [candidate])]
            )
            let peer = try await accepted.value
            #expect(try await harness.sentStanza(matching: Self.isCandidateUsed("responder-direct")) != nil)
            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )

            let module = harness.module
            let ready = try await boundedOutcome { try await module.awaitTransportReady(sid: sid) }
            guard case .success? = ready else {
                Issue.record("Expected the reached candidate to become the transport, got \(String(describing: ready))")
                return
            }
            #expect(try await Self.transfer(on: module, sid: sid, to: peer) == [1, 2, 3])
            #expect(harness.sentJingleCount(action: JingleAction.transportReplace.rawValue) == 0)
            await peer.close()
            await responder.close()
        }

        /// A responder proxy this side reaches carries the file only once the responder's `<activated/>` arrives
        /// (XEP-0260 §2.4).
        @Test
        func `An initiator sends over the responder's proxy it reached once the responder activates it`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            let proxy = SOCKS5Listener()
            let port = try await proxy.start()
            let destination = try Self.responderDestination(harness, sid: sid)
            let accepted = Task { try await proxy.accept(expectedDstAddr: destination, timeout: 5) }
            let candidate = SOCKS5Transport.Candidate(
                cid: "responder-proxy", host: "127.0.0.1", port: port, jid: Self.proxyJID, priority: 100, type: .proxy
            )

            try harness.receive(
                action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [harness.acceptedContent(sid: sid, candidates: [candidate])]
            )
            let peer = try await accepted.value
            #expect(try await harness.sentStanza(matching: Self.isCandidateUsed("responder-proxy")) != nil)
            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "candidate-error"))]
            )

            let module = harness.module
            #expect(module.state.withLock { $0.resources[sid]?.pendingProxy != nil })
            let ready = Task { try await module.awaitTransportReady(sid: sid) }
            #expect(try await boundedOutcome(timeout: .milliseconds(300)) { try await ready.value } == nil)

            try harness.receive(
                action: JingleAction.transportInfo.rawValue, sid: sid,
                payload: [JingleInitiatorHarness.socks5Info(XMLElement(name: "activated", attributes: ["cid": "responder-proxy"]))]
            )
            guard case .success? = try await boundedOutcome(of: { try await ready.value }) else {
                Issue.record("Expected the activated proxy to become the transport")
                return
            }
            #expect(try await Self.transfer(on: module, sid: sid, to: peer) == [1, 2, 3])
            await peer.close()
            await proxy.close()
        }

        /// XEP-0260 §2.4.
        @Test
        func `An initiator's higher-priority dial beats the peer's candidate-used and closes the listener's connection`() async throws {
            let harness = JingleInitiatorHarness(timing: JingleTiming(senderConfirmationWait: .milliseconds(300)))
            let sid = try await harness.initiate()
            let responder = SOCKS5Listener()
            let port = try await responder.start()
            let destination = try Self.responderDestination(harness, sid: sid)
            let candidate = SOCKS5Transport.Candidate(
                cid: "responder-direct", host: "127.0.0.1", port: port, jid: JingleInitiatorHarness.peer.description,
                priority: .max, type: .direct
            )

            try harness.receive(
                action: JingleAction.sessionAccept.rawValue, sid: sid, payload: [harness.acceptedContent(sid: sid, candidates: [candidate])]
            )
            let inbound = try await harness.connectToDirectCandidate(sid: sid)
            try harness.nominateDirectCandidate(sid: sid)
            let peer = try await responder.accept(expectedDstAddr: destination, timeout: 5)
            #expect(try await harness.sentStanza(matching: Self.isCandidateUsed("responder-direct")) != nil)

            guard case .failure? = try await boundedOutcome(of: { _ = try await inbound.receive(1) }) else {
                Issue.record("Expected the connection the listener accepted to close")
                return
            }
            #expect(try await Self.transfer(on: harness.module, sid: sid, to: peer) == [1, 2, 3])
            await inbound.close()
            await peer.close()
            await responder.close()
        }
    }
}
