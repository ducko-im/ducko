import Logging

private let log = Logger(label: "im.ducko.xmpp.jingle")

/// The initiator's side of XEP-0260 §2.3-2.4: it dials the candidates the responder's session-accept offers while its
/// listener waits for the responder, reports what its dial reached, and settles the transport from both sides' reports.
extension JingleModule {
    /// What one side reported about the other's candidates (XEP-0260 §2.3).
    enum CandidateReport {
        case used(SOCKS5Transport.Candidate)
        case error
    }

    /// The reports an initiator settles its SOCKS5 transport from (XEP-0260 §2.4).
    struct CandidateNomination {
        /// Which side's candidate carries the file, or neither when both reported an error.
        enum Outcome {
            case own(SOCKS5Transport.Candidate)
            case peer(SOCKS5Transport.Candidate)
            case neither
        }

        /// The candidates the responder's session-accept offered.
        var responderCandidates: [SOCKS5Transport.Candidate] = []
        /// Set by the session-accept that starts this side's dial, so a peer report waits for this side's own.
        var isDialing = false
        var own: CandidateReport?
        var peer: CandidateReport?
        /// The connection this side's candidate-used names, held until the nomination settles.
        var dialed: SOCKS5Connection?
        var isSettled = false

        /// The outcome once both reports are in. Before its dial starts, this side has nothing to report, so the peer's
        /// report decides alone. Equal priorities go to the initiator's choice, which is this side's.
        var outcome: Outcome? {
            guard !isSettled, let peer, let own = own ?? (isDialing ? nil : .error) else { return nil }
            switch (own, peer) {
            case (.error, .error):
                return .neither
            case let (.used(candidate), .error):
                return .own(candidate)
            case let (.error, .used(candidate)):
                return .peer(candidate)
            case let (.used(ownCandidate), .used(peerCandidate)):
                return ownCandidate.priority >= peerCandidate.priority ? .own(ownCandidate) : .peer(peerCandidate)
            }
        }

        /// Whether `candidate` can still win once dialed. A peer that used one of higher priority settles it already.
        func canWin(_ candidate: SOCKS5Transport.Candidate) -> Bool {
            guard case let .used(peerCandidate)? = peer else { return true }
            return candidate.priority >= peerCandidate.priority
        }

        mutating func takeDialed() -> SOCKS5Connection? {
            defer { dialed = nil }
            return dialed
        }
    }

    /// What settling a nomination released, for the caller to act on outside the lock.
    private struct SettledNomination {
        let outcome: CandidateNomination.Outcome
        var wake: CheckedContinuation<Void, Error>?
        var unselected: SOCKS5Connection?
        var listener: SOCKS5Listener?
    }

    /// Takes the candidates the responder's session-accept offers for this side's stream, which this side dials before it
    /// reports. A repeated session-accept, or one after the nomination settled, changes nothing. Must be called within a
    /// state.withLock.
    static func takeResponderCandidates(in jingle: XMLElement, sid: String, state: inout State) {
        guard let session = state.resources[sid]?.session, case let .socks5(offered) = session.content.transport,
              var nomination = state.resources[sid]?.nomination, !nomination.isDialing, !nomination.isSettled else { return }
        nomination.isDialing = true
        if let accepted = transportElement(in: jingle).flatMap(SOCKS5Transport.init(from:)), accepted.sid == offered.sid {
            nomination.responderCandidates = accepted.candidates
        }
        state.resources[sid]?.nomination = nomination
    }

    /// The SOCKS5 DST.ADDR for a connection to a candidate `offerer` sent: the SHA-1 of the stream id, the offerer's JID
    /// and the other party's JID (XEP-0260 §2.2).
    func destinationAddress(in session: JingleSession, candidateOfferedBy offerer: JingleSession.Role) -> String {
        guard case let .socks5(transport) = session.content.transport else { return "" }
        let ownJID = state.withLock { $0.context?.connectedJID()?.description ?? "" }
        let peerJID = session.peer.description
        let (offererJID, otherJID) = offerer == session.role ? (ownJID, peerJID) : (peerJID, ownJID)
        return SOCKS5Connection.destinationAddress(sid: transport.sid, initiatorJID: offererJID, targetJID: otherJID)
    }

    /// Dials `candidates` in order until one connects, skipping each one `shouldContinue` refuses.
    func tryConnectCandidates(
        _ candidates: [SOCKS5Transport.Candidate],
        dstAddr: String,
        while shouldContinue: (SOCKS5Transport.Candidate) -> Bool = { _ in true }
    ) async -> (connection: SOCKS5Connection, candidate: SOCKS5Transport.Candidate)? {
        for candidate in candidates where shouldContinue(candidate) {
            let connection = SOCKS5Connection()
            do {
                // A proxy is optional, so a dial to one is bounded: waiting out the socket's own default would hold up
                // every candidate behind it and the IBB fallback after those.
                if case .proxy = candidate.type {
                    try await connection.connect(
                        host: candidate.host, port: candidate.port, destinationAddress: dstAddr,
                        timeout: Self.seconds(timing.proxyConnectWait)
                    )
                } else {
                    try await connection.connect(host: candidate.host, port: candidate.port, destinationAddress: dstAddr)
                }
                return (connection, candidate)
            } catch {
                log.debug("SOCKS5 candidate \(candidate.cid) failed: \(error)")
                await connection.close()
            }
        }
        return nil
    }

    /// Waits for the responder on this side's listener while dialing the responder's candidates.
    func connectAsInitiator(sid: String, session: JingleSession, listener: SOCKS5Listener?, context: ModuleContext) async {
        await withDiscardingTaskGroup { group in
            if let listener {
                group.addTask { await self.acceptPeerConnection(on: listener, sid: sid, session: session, context: context) }
            }
            group.addTask { await self.dialResponderCandidates(sid: sid, session: session, context: context) }
        }
    }

    /// Accepts the responder's connection to this side's direct candidate. It carries the file only once the nomination
    /// settles on it.
    private func acceptPeerConnection(on listener: SOCKS5Listener, sid: String, session: JingleSession, context: ModuleContext) async {
        defer { cleanupListener(sid: sid) }
        do {
            let connection = try await listener.accept(expectedDstAddr: destinationAddress(in: session, candidateOfferedBy: .initiator))
            handleConnectionSuccess(sid: sid, result: (connection, Self.listenerCID), session: session, context: context)
        } catch {
            log.debug("Listener accept failed: \(error)")
        }
    }

    /// Dials the responder's candidates by priority, skipping any that could no longer win against the one the peer
    /// used (XEP-0260 §2.3), reports the result, and settles the nomination with it.
    private func dialResponderCandidates(sid: String, session: JingleSession, context: ModuleContext) async {
        let candidates = state.withLock { state -> [SOCKS5Transport.Candidate]? in
            guard let nomination = state.resources[sid]?.nomination, nomination.isDialing, nomination.own == nil else { return nil }
            return nomination.responderCandidates
        }
        guard let candidates else { return }

        let result = await tryConnectCandidates(
            candidates.sorted { $0.priority > $1.priority },
            dstAddr: destinationAddress(in: session, candidateOfferedBy: .responder)
        ) { candidate in
            state.withLock { state in
                Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state)
                    && state.resources[sid]?.nomination.canWin(candidate) == true
            }
        }
        let report: CandidateReport = result.map { .used($0.candidate) } ?? .error
        let isCurrent = state.withLock { state -> Bool in
            guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state) else { return false }
            state.resources[sid]?.nomination.own = report
            state.resources[sid]?.nomination.dialed = result?.connection
            return true
        }
        guard isCurrent else {
            await result?.connection.close()
            return
        }

        switch report {
        case let .used(candidate):
            sendCandidateUsed(sid: sid, cid: candidate.cid, session: session, context: context)
        case .error:
            sendTransportInfo(sid: sid, session: session, context: context, transportChild: XMLElement(name: "candidate-error"))
        }
        settleNomination(sid: sid, session: session, context: context)
    }

    /// Records the peer's report on this side's candidates, then settles the nomination once its outcome is decided.
    /// Only the peer's first report counts.
    func recordPeerReport(_ report: CandidateReport, sid: String, session: JingleSession, context: ModuleContext) {
        let isFirst = state.withLock { state -> Bool in
            guard state.resources[sid]?.session?.offerID == session.offerID, state.resources[sid]?.nomination.peer == nil else {
                return false
            }
            state.resources[sid]?.nomination.peer = report
            return true
        }
        guard isFirst else { return }
        settleNomination(sid: sid, session: session, context: context)
    }

    /// Applies the nomination once its outcome is decided (XEP-0260 §2.4): this side's dialed connection becomes the
    /// transport, the peer's choice is used, or the transfer falls back to IBB.
    private func settleNomination(sid: String, session: JingleSession, context: ModuleContext) {
        let settled = state.withLock { state -> SettledNomination? in
            guard Self.socks5OutcomeOpen(sid: sid, offerID: session.offerID, in: state),
                  var nomination = state.resources[sid]?.nomination, let outcome = nomination.outcome else { return nil }
            nomination.isSettled = true
            let dialed = nomination.takeDialed()
            state.resources[sid]?.nomination = nomination
            guard case let .own(candidate) = outcome, let dialed else {
                return SettledNomination(outcome: outcome, unselected: dialed)
            }
            return Self.useOwnConnection(dialed, candidate: candidate, sid: sid, state: &state)
        }
        guard let settled else { return }

        if let unselected = settled.unselected {
            Task { await unselected.close() }
        }
        if let listener = settled.listener {
            Task { await listener.close() }
        }
        settled.wake?.resume()
        switch settled.outcome {
        case .own:
            break
        case let .peer(candidate):
            usePeerCandidate(candidate, sid: sid, session: session, context: context)
        case .neither:
            fallBackToIBB(sid: sid, context: context)
        }
    }

    /// Makes the connection this side dialed the transport: at once for a direct candidate, and once the responder
    /// activates it for a proxy (XEP-0260 §2.4). The listener stops, and a connection it accepted closes unchosen. Must
    /// be called within a state.withLock.
    private static func useOwnConnection(
        _ connection: SOCKS5Connection, candidate: SOCKS5Transport.Candidate, sid: String, state: inout State
    ) -> SettledNomination {
        var settled = SettledNomination(
            outcome: .own(candidate), unselected: state.resources[sid]?.takePendingDirect(), listener: state.resources[sid]?.takeListener()
        )
        switch candidate.type {
        case .direct:
            settled.wake = publishSOCKS5(connection, cid: candidate.cid, sid: sid, state: &state)
        case .proxy:
            state.resources[sid]?.pendingProxy = PendingProxy(connection: connection, cid: candidate.cid)
        }
        return settled
    }
}

extension SOCKS5Transport.CandidateType {
    /// A candidate's priority per XEP-0260 §2.2: (2^16) × the type preference the spec suggests, plus a local preference
    /// that ranks candidates of one type.
    func priority(localPreference: UInt16) -> UInt32 {
        let typePreference: UInt32 = switch self {
        case .direct: 126
        case .proxy: 10
        }
        return (1 << 16) * typePreference + UInt32(localPreference)
    }
}
