/// Ends a send once its bytes are written: only the receiver's confirmation counts it as delivered, and a send nothing
/// confirms within the wait fails.
extension JingleModule {
    /// Outcome of resolving a send's end under the lock.
    private enum SendEnd {
        case committed(JingleTransportKind, SessionResources)
        case confirmed
        case failed(any Error)
        /// A write failed before the receiver confirmed, and the session was removed with it.
        case abandoned(any Error, SessionResources)
        /// Nothing confirmed the send yet, and its confirmation wait has not elapsed.
        case unconfirmed
        /// The confirmation wait elapsed with nothing confirming the send, which fails as unconfirmed. The session was
        /// removed with that decision, so a peer's end that lands afterwards finds no session to report.
        case expired(SessionResources)
    }

    /// Commits, returns from, or fails a send whose bytes were written or whose write threw.
    func finishSend(sid: String, offerID: String, writeError: (any Error)?, context: ModuleContext) async throws {
        let deadline = ContinuousClock.now + timing.senderConfirmationWait
        if writeError != nil {
            try? await awaitSendConfirmation(sid: sid, offerID: offerID, until: ContinuousClock.now + timing.peerEndGrace)
        }
        var end = resolveSendEnd(sid: sid, offerID: offerID, writeError: writeError, waitElapsed: false)
        if case .unconfirmed = end {
            do {
                try await awaitSendConfirmation(sid: sid, offerID: offerID, until: deadline)
            } catch {
                state.withLock { state in
                    guard Self.session(sid, offerID: offerID, in: state) != nil else { return }
                    state.resources[sid]?.send?.isOwnerActive = false
                }
                throw error
            }
            end = resolveSendEnd(sid: sid, offerID: offerID, writeError: nil, waitElapsed: true)
        }

        switch end {
        case let .committed(transport, resources):
            resources.cancel(with: JingleError.sessionNotFound)
            context.emitEvent(.jingleFileTransferCompleted(sid: sid, offerID: offerID, transport: transport))
        case .confirmed:
            // The receiver normally ends the session itself; end it once the wait elapses if it hasn't.
            let cleanup = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
                try? await self?.terminateSession(sid: sid, reason: .success, offerID: offerID)
            }
            let isLive = state.withLock { state -> Bool in
                guard Self.session(sid, offerID: offerID, in: state) != nil, state.resources[sid]?.send != nil else { return false }
                state.resources[sid]?.send?.cleanupTask = cleanup
                return true
            }
            if !isLive { cleanup.cancel() }
        case let .failed(error):
            throw error
        case let .abandoned(error, resources):
            // Reported like any other failed session, and the peer is told rather than left waiting for the rest.
            endAbandonedSession(sid: sid, resources: resources, reason: .incomplete, terminateReason: .failedTransport, context: context)
            throw error
        case .unconfirmed:
            // Resolved again once the wait elapsed, which never leaves it unconfirmed.
            break
        case let .expired(resources):
            // Only the receiver can say the file arrived, so a send nothing confirmed fails. The session is already
            // gone, so the terminate goes out best effort.
            let reason = JingleTransferFailureReason.unconfirmed
            endAbandonedSession(sid: sid, resources: resources, reason: reason, terminateReason: .timeout, context: context)
            throw JingleError.transportFailed(reason.displayText)
        }
    }

    /// Resolves a send's end under the lock. Once `waitElapsed`, a send nothing confirmed fails as unconfirmed, and its
    /// session goes in the same critical section: a peer's end either removed it first, and its failure event reports
    /// the end, or finds no session afterwards.
    private func resolveSendEnd(sid: String, offerID: String, writeError: (any Error)?, waitElapsed: Bool) -> SendEnd {
        state.withLock { state -> SendEnd in
            guard Self.session(sid, offerID: offerID, in: state) != nil, var send = state.resources[sid]?.send else {
                return .failed(writeError ?? JingleError.sessionNotFound)
            }
            switch send.confirmation {
            case .terminatedSuccess:
                guard let resources = detachSessionResources(sid: sid, state: &state) else { return .failed(JingleError.sessionNotFound) }
                return .committed(send.transport, resources)
            case .received:
                // The receiver already has every byte, so a write that failed afterwards changes nothing.
                send.isOwnerActive = false
                state.resources[sid]?.send = send
                return .confirmed
            case nil:
                // A write that failed before the receiver confirmed leaves nothing to carry on with. The session goes in the
                // same critical section, so neither a later session under the sid nor a peer's end can slip in between.
                if let writeError {
                    guard let resources = detachSessionResources(sid: sid, state: &state) else { return .failed(writeError) }
                    return .abandoned(writeError, resources)
                }
                guard waitElapsed else { return .unconfirmed }
                guard let resources = detachSessionResources(sid: sid, state: &state) else { return .failed(JingleError.sessionNotFound) }
                return .expired(resources)
            }
        }
    }

    /// Waits until the receiver confirms the send or `deadline` passes. Throws when the session is torn down meanwhile.
    private func awaitSendConfirmation(sid: String, offerID: String, until deadline: ContinuousClock.Instant) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let registration = state.withLock { state -> WaitRegistration in
                guard Self.session(sid, offerID: offerID, in: state) != nil, let send = state.resources[sid]?.send else { return .gone }
                guard send.confirmation == nil else { return .ready }
                state.resources[sid]?.send?.wait = continuation
                return .waiting
            }
            switch registration {
            case .gone:
                continuation.resume(throwing: JingleError.sessionNotFound)
            case .ready:
                continuation.resume()
            case .waiting:
                Task { [weak self] in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    // The timer outlives an ended session, so it only releases the wait of the session that started it.
                    let wait = self?.state.withLock { state -> CheckedContinuation<Void, Error>? in
                        guard Self.session(sid, offerID: offerID, in: state) != nil else { return nil }
                        let wait = state.resources[sid]?.send?.wait
                        state.resources[sid]?.send?.wait = nil
                        return wait
                    }
                    wait?.resume()
                }
            }
        }
    }
}
