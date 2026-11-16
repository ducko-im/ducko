import Darwin

/// How a presence hold ended, used to pick the process exit code or rethrow the hold work's error.
enum HoldEndReason {
    case expired
    case interrupted(Int32)
    case workFailed
}

/// Which lifetime a `presence` hold uses.
enum PresenceHoldLifetime {
    case bounded(Duration)
    case keepAlive
}

/// Process exit code (POSIX 128 + signal number) for a trapped interrupt signal — e.g. SIGINT→130, SIGTERM→143,
/// SIGHUP→129.
func exitCode(forSignal signo: Int32) -> Int32 {
    128 + signo
}

/// Single state holder arbitrating a presence hold's end across the connect/apply/hold/teardown phases.
///
/// Whichever happens first — a trapped signal, the hold work ending naturally, or the work failing — is
/// yielded once on `ends`. A SIGINT or SIGTERM arriving *during* teardown flips to `aborting` and tells the
/// consumer to hard-exit immediately. The "second signal" is detected via this state, never by counting handler
/// invocations, because `DispatchSourceSignal` coalesces repeats. `beginTeardown()` on the natural-end path also
/// flips out of `holding`, so a SIGINT or SIGTERM during that teardown likewise hard-exits on its next fire.
actor HoldArbiter {
    private enum Phase {
        case holding
        case tearingDown
        case aborting
    }

    /// Yields the first end reason exactly once, then finishes. Single-consumer.
    nonisolated let ends: AsyncStream<HoldEndReason>
    private let endContinuation: AsyncStream<HoldEndReason>.Continuation
    private var phase: Phase = .holding
    private var recorded = false

    init() {
        (self.ends, self.endContinuation) = AsyncStream.makeStream()
    }

    /// Records a trapped signal. Returns `true` when the caller must perform the immediate `Foundation.exit`
    /// hard abort (a second signal after teardown began). A closing terminal sends SIGHUP more than once, from the
    /// shell and again from the kernel, so a SIGHUP during teardown leaves it running.
    func recordSignal(_ signo: Int32) -> Bool {
        switch phase {
        case .holding:
            record(.interrupted(signo))
            return false
        case .tearingDown:
            guard signo != SIGHUP else { return false }
            phase = .aborting
            return true
        case .aborting:
            return false
        }
    }

    /// The hold work ended naturally (the `--for` window elapsed).
    func recordExpiry() {
        record(.expired)
    }

    /// The hold work threw before or during the hold (e.g. a connect failure).
    func recordWorkFailed() {
        record(.workFailed)
    }

    /// Marks teardown as started so a further SIGINT or SIGTERM forces a hard exit. Idempotent. `record()` owns
    /// finishing the `ends` stream, so this only flips the phase.
    func beginTeardown() {
        if case .holding = phase { phase = .tearingDown }
    }

    private func record(_ reason: HoldEndReason) {
        if case .holding = phase { phase = .tearingDown }
        guard !recorded else { return }
        recorded = true
        endContinuation.yield(reason)
        endContinuation.finish()
    }
}
