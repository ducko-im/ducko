import Logging

private let log = Logger(label: "im.ducko.xmpp.jingle")

/// Ends a session whose peer is gone, judged only by signals that session can trust. A session not yet carrying data ends
/// once its peer's unavailable presence stays unanswered for a grace period. A claimed IBB receive ends once its blocks
/// stop for the stall wait. A session carrying data otherwise relies on its transport's own failure signals.
extension JingleModule {
    // MARK: - Presence Grace

    public func handlePresence(_ presence: XMPPPresence) {
        guard presence.presenceType == .unavailable, let from = presence.from else { return }
        state.withLock { state in
            for (sid, resources) in state.resources where resources.peerGoneTask == nil {
                guard let session = resources.session, Self.isPeer(session.peer, coveredBy: from),
                      !Self.isCarryingData(sid: sid, in: state) else { continue }
                state.resources[sid]?.peerGoneTask = startPeerGoneGrace(sid: sid, offerID: session.offerID)
            }
        }
    }

    /// Cancels the grace of session `sid`, whose peer just sent a Jingle stanza for it.
    func notePeerActivity(sid: String) {
        let grace = state.withLock { $0.resources[sid]?.takePeerGoneTask() }
        grace?.cancel()
    }

    /// Cancels the grace of the session IBB stream `ibbSID` belongs to, when `from` is that session's peer.
    func notePeerActivity(ibbSID: String?, from: JID?) {
        let grace = state.withLock { state -> Task<Void, Never>? in
            guard let ibbSID, let sid = Self.ibbSessionID(for: ibbSID, from: from, state: state) else { return nil }
            return state.resources[sid]?.takePeerGoneTask()
        }
        grace?.cancel()
    }

    /// Whether an unavailable presence from `from` covers `peer`: the peer's own full JID, or its bare JID for every
    /// resource.
    private static func isPeer(_ peer: FullJID, coveredBy from: JID) -> Bool {
        switch from {
        case let .full(fullJID): fullJID == peer
        case let .bare(bareJID): bareJID == peer.bareJID
        }
    }

    /// Whether the session under `sid` is moving data: a connected SOCKS5 bytestream, or an IBB stream with a send or a
    /// claimed receive under way. Must be called within a state.withLock.
    private static func isCarryingData(sid: String, in state: State) -> Bool {
        guard let resources = state.resources[sid], let session = resources.session else { return false }
        if case .connected = session.transportState { return true }
        return resources.ibb != nil && (resources.send != nil || resources.receive?.isClaimed == true)
    }

    /// Starts the grace after which a session whose peer went unavailable ends. Must be called within a state.withLock.
    private func startPeerGoneGrace(sid: String, offerID: String) -> Task<Void, Never> {
        let grace = timing.peerUnavailableGrace
        return Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, let self else { return }
            peerGoneGraceElapsed(sid: sid, offerID: offerID)
        }
    }

    private func peerGoneGraceElapsed(sid: String, offerID: String) {
        guard let context = state.withLock({ $0.context }) else { return }
        // Checked again under the lock: the peer may have spoken since, or the session started carrying data.
        let ended = abandonTransport(sid: sid, offerID: offerID, reason: .gone, terminateReason: .gone, context: context) { state in
            state.resources[sid]?.peerGoneTask != nil && !Self.isCarryingData(sid: sid, in: state)
        }
        if ended {
            log.debug("Ended a Jingle session whose peer went unavailable, sid: \(sid)")
        }
    }

    // MARK: - IBB Stall

    /// Arms the wait after which a claimed IBB receive that stopped getting blocks finalizes with what it holds. The wait
    /// counts from the last block, or from now when none arrived yet. Must be called within a state.withLock.
    func armIBBStall(sid: String, offerID: String, receive: inout ReceiveState) {
        guard receive.stallTask == nil else { return }
        let armedAt = ContinuousClock.now
        let firstDeadline = (receive.lastBlockAt ?? armedAt) + timing.receiveStallWait
        receive.stallTask = Task { [weak self] in
            var deadline = firstDeadline
            while true {
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let later = self?.ibbStallWaitElapsed(sid: sid, offerID: offerID, armedAt: armedAt) else { return }
                deadline = later
            }
        }
    }

    /// Wakes a claimed IBB receive once the stall wait passed since its last block, so it finalizes with what it holds.
    /// Returns the deadline to sleep until instead when a block arrived meanwhile, or `nil` once the wait is over.
    private func ibbStallWaitElapsed(sid: String, offerID: String, armedAt: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        let wait = timing.receiveStallWait
        let outcome = state.withLock { state -> (wake: CheckedContinuation<Void, Error>?, later: ContinuousClock.Instant?) in
            guard state.resources[sid]?.session?.offerID == offerID, let receive = state.resources[sid]?.receive,
                  let wake = receive.wake else { return (nil, nil) }
            let deadline = (receive.lastBlockAt ?? armedAt) + wait
            guard deadline <= now else { return (nil, deadline) }
            state.resources[sid]?.receive?.wake = nil
            return (wake, nil)
        }
        if let wake = outcome.wake {
            log.debug("IBB receive stalled, sid: \(sid)")
            wake.resume()
        }
        return outcome.later
    }
}

extension JingleModule.SessionResources {
    mutating func takePeerGoneTask() -> Task<Void, Never>? {
        defer { peerGoneTask = nil }
        return peerGoneTask
    }
}
