extension XMPPClient {
    /// `isOpen` flips true once the caps-bearing presence is on the wire (fresh connect), immediately on
    /// resume, or on teardown so late awaits never hang; `waiters` holds services suspended in
    /// ``awaitInitialPresenceSent()`` until then.
    struct PresenceReadiness {
        var isOpen: Bool = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    /// Whether the session's setup has completed. `pending` holds the sends waiting for it, and `closed` refuses them
    /// before any connect and once the session ends or the connect fails.
    enum SessionReadiness {
        case pending([CheckedContinuation<Void, any Error>])
        case ready
        case closed
    }

    // MARK: - Initial Presence Readiness

    /// Suspends until the caps-bearing initial available presence has been sent on a fresh connect, or
    /// returns immediately on a resumed session (where it is not re-sent). The PEP-reacting services
    /// (OMEMO, Avatar, Bookmarks) await this before issuing PEP retrieves/publishes so the server has seen
    /// this resource's caps first (XEP-0163 §3.3.2). Also resolves on connection failure / `disconnect()`,
    /// so a waiting service never hangs when presence never goes out.
    public nonisolated func awaitInitialPresenceSent() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-check the flag inside the critical section before suspending, so a `settle` that runs
            // between an out-of-lock check and the append can't leave the continuation orphaned.
            let alreadyOpen = presenceReadinessLock.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    /// Resolves all current waiters, setting the gate's open state. Idempotent. `open: true` opens the gate
    /// (caps sent, or teardown so late awaits never hang); `open: false` re-gates for a new attempt.
    func settleInitialPresenceReadiness(open: Bool) {
        let waiters = presenceReadinessLock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = open
            let pending = state.waiters
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Session Readiness

    /// Suspends until the session's setup has completed, on a fresh connect or a resume. Throws
    /// ``XMPPClientError/notConnected`` when the session ends or the connect fails first, and at once when no connect
    /// has started or the session has ended.
    nonisolated func awaitSessionReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let outcome = sessionReadinessLock.withLock { state -> Result<Void, any Error>? in
                switch state {
                case var .pending(waiters):
                    waiters.append(continuation)
                    state = .pending(waiters)
                    return nil
                case .ready:
                    return .success(())
                case .closed:
                    return .failure(XMPPClientError.notConnected)
                }
            }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    /// Moves the gate to `readiness`, resuming every waiter: with success once the session is ready, else with
    /// ``XMPPClientError/notConnected``.
    func settleSessionReadiness(_ readiness: SessionReadiness) {
        let waiters = sessionReadinessLock.withLock { state -> [CheckedContinuation<Void, any Error>] in
            let pending: [CheckedContinuation<Void, any Error>] = if case let .pending(waiters) = state { waiters } else { [] }
            state = readiness
            return pending
        }
        let outcome: Result<Void, any Error> = if case .ready = readiness { .success(()) } else { .failure(XMPPClientError.notConnected) }
        for waiter in waiters {
            waiter.resume(with: outcome)
        }
    }
}
