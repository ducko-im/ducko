import Darwin
import Dispatch

/// Process-global trap of the terminating signals (`trappableTerminatingSignals()`) that bridges signal delivery into
/// an `AsyncStream<Int32>` yielding the signal number (so the consumer can exit with `130`, `143` or `129`).
///
/// Intended only for the single foreground `presence` hold — there is no nested use. The returned stream is
/// **single-consumer**: the hold's arbiter is its sole reader for the whole lifetime; do not spin up a second
/// `for await` on it.
struct InterruptMonitor {
    let signals: AsyncStream<Int32>
    private let sources: [any DispatchSourceProtocol]

    static func install() -> InterruptMonitor {
        let (stream, continuation) = AsyncStream<Int32>.makeStream()
        let queue = DispatchQueue(label: "im.ducko.cli.interrupt-monitor")
        let sources = trappableTerminatingSignals().map { signo -> any DispatchSourceProtocol in
            // Ignore the default disposition so the signal feeds the dispatch source instead of terminating the
            // process (matches CLIBootstrap's SIGPIPE handling).
            signal(signo, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            // `DispatchSourceSignal` coalesces repeats — the consumer must treat a fire while already tearing
            // down as "second signal" via its own state, not by counting handler invocations.
            source.setEventHandler { continuation.yield(signo) }
            source.activate()
            return source
        }
        return InterruptMonitor(signals: stream, sources: sources)
    }

    /// Cancels the underlying dispatch sources. Call once the hold has fully torn down.
    func cancel() {
        for source in sources {
            source.cancel()
        }
    }
}
