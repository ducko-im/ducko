/// Says goodbye before the stream closes, and lets a peer's own end win over the broken bytestream it leaves behind.
extension JingleModule {
    // MARK: - Lifecycle

    /// Ends every session and preparation while the stream is still up, so each peer learns this side went away rather
    /// than waiting on a transfer that cannot finish. No session starts after this.
    public func prepareForDisconnect() async {
        let (context, ended) = await endAllSessions { $0.isClosing = true }
        guard let context else { return }
        for session in ended {
            try? await sendSessionTerminate(sid: session.sid, peer: session.peer, reason: .gone, context: context)
        }
    }

    public func handleDisconnect() async {
        _ = await endAllSessions { $0.cachedProxy65 = nil }
    }

    /// A session the connection's end took with it.
    private struct EndedSession {
        let sid: String
        let peer: FullJID
    }

    /// Detaches every session and preparation, applying `update` in the same critical section, and reports each session
    /// as failed by the disconnect once its waits are cancelled and its transport is closed. Returns those sessions.
    private func endAllSessions(
        _ update: @Sendable (inout State) -> Void
    ) async -> (context: ModuleContext?, ended: [EndedSession]) {
        let (context, detached) = state.withLock { state -> (ModuleContext?, [(sid: String, resources: SessionResources)]) in
            update(&state)
            let detached = Array(state.resources.keys).compactMap { sid in
                detachSessionResources(sid: sid, state: &state).map { (sid, $0) }
            }
            return (state.context, detached)
        }
        for (_, resources) in detached {
            resources.continuations.cancel(with: JingleError.notConnected)
            await resources.closeTransport()
        }
        var ended: [EndedSession] = []
        for (sid, resources) in detached {
            guard let peer = resources.session?.peer else { continue }
            context?.emitEvent(.jingleFileTransferFailed(sid: sid, offerID: resources.offerID, reason: .disconnected))
            ended.append(EndedSession(sid: sid, peer: peer))
        }
        return (context, ended)
    }

    // MARK: - Peer-End Grace

    /// Waits up to the peer-end grace for the peer to end a SOCKS5 receive whose read ended short. A peer's terminate in
    /// that window removes the session and reports its reason. Throws when the session ended meanwhile.
    func awaitPeerEnd(sid: String, offerID: String) async throws {
        let grace = timing.peerEndGrace
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = state.withLock { state -> WaitRegistration in
                guard state.resources[sid]?.session?.offerID == offerID, let receive = state.resources[sid]?.receive else { return .gone }
                guard receive.peerEnd == nil else { return .ready }
                state.resources[sid]?.receive?.wake = continuation
                return .waiting
            }
            switch registration {
            case .gone:
                continuation.resume(throwing: JingleError.sessionNotFound)
            case .ready:
                continuation.resume()
            case .waiting:
                Task { [weak self] in
                    try? await Task.sleep(for: grace)
                    // The timer outlives an ended session, so it only releases the wait of the session that started it.
                    let wake = self?.state.withLock { state -> CheckedContinuation<Void, Error>? in
                        guard state.resources[sid]?.session?.offerID == offerID else { return nil }
                        let wake = state.resources[sid]?.receive?.wake
                        state.resources[sid]?.receive?.wake = nil
                        return wake
                    }
                    wake?.resume()
                }
            }
        }
    }
}
