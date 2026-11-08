import ArgumentParser
import DuckoCore
import Foundation

extension DuckoCLI {
    struct Presence: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Get or set presence status"
        )

        @OptionGroup var global: GlobalOptions

        @OptionGroup var accountOption: AccountOption

        /// `.customLong("for")` ships `--for` (`.long` would derive `--hold` from the property name); the
        /// property stays `hold` because `for` is a reserved keyword.
        @Option(name: .customLong("for"), help: "Hold the status for a bounded window, then clean-disconnect (e.g. 30s, 15m, 2h)")
        var hold: String?

        @Flag(name: .long, help: "Hold the status until interrupted (Ctrl-C), then clean-disconnect")
        var keepAlive: Bool = false

        @Argument(help: "Status: available, away, xa, dnd, offline")
        var status: String?

        @Argument(help: "Optional status message")
        var message: String?

        func validate() throws {
            if hold != nil, keepAlive {
                throw ValidationError("--for and --keep-alive are mutually exclusive.")
            }
            let wantsLifetime = hold != nil || keepAlive
            if wantsLifetime, status == nil {
                throw ValidationError("--for/--keep-alive require a status to hold (e.g. presence away --keep-alive).")
            }
            if let status {
                guard let presenceStatus = PresenceService.PresenceStatus(rawValue: status) else {
                    throw ValidationError(CLIError.invalidPresenceStatus(status).localizedDescription)
                }
                if wantsLifetime, presenceStatus == .offline {
                    throw ValidationError("offline cannot be held — it means \"go unavailable now\", which is inherently one-shot.")
                }
            }
            if let hold {
                do {
                    _ = try parseHoldDuration(hold)
                } catch let error as CLIError {
                    throw ValidationError(error.localizedDescription)
                }
            }
        }

        func run() async throws {
            let formatter = global.formatter

            let prepared = try await ConnectedOperation.prepare(formatter: formatter, account: accountOption.account)
            let env = prepared.environment
            let selectedAccount = prepared.account
            let password = prepared.password

            if let lifetime = try resolvedLifetime(), let status {
                let presenceStatus = try requirePresenceStatus(status)
                let holdContext = PresenceHoldContext(
                    formatter: formatter, environment: env, account: selectedAccount, password: password
                )
                try await runPresenceHold(
                    lifetime: lifetime, context: holdContext, status: presenceStatus, message: message
                )
                return
            }

            try await ConnectedOperation.run(environment: env, account: selectedAccount, password: password) {
                if let status {
                    let presenceStatus = try requirePresenceStatus(status)
                    await applyPresence(presenceStatus, message: message, environment: env, accountID: selectedAccount.id)
                    print(formatter.formatPresence(jid: selectedAccount.jid, status: presenceStatus.rawValue, message: message))
                    printToStandardError("Note: this status is session-scoped and reverts to unavailable when the command exits. Use --for <duration> or --keep-alive to hold it.")
                } else {
                    let (myPresence, myMessage) = await MainActor.run {
                        (env.presenceService.myPresence, env.presenceService.myStatusMessage)
                    }
                    print(formatter.formatPresence(jid: selectedAccount.jid, status: myPresence.rawValue, message: myMessage))
                }
            }
        }

        private func resolvedLifetime() throws -> PresenceHoldLifetime? {
            if let hold {
                return try .bounded(parseHoldDuration(hold))
            }
            return keepAlive ? .keepAlive : nil
        }

        private func requirePresenceStatus(_ status: String) throws -> PresenceService.PresenceStatus {
            guard let presenceStatus = PresenceService.PresenceStatus(rawValue: status) else {
                throw CLIError.invalidPresenceStatus(status)
            }
            return presenceStatus
        }
    }
}

/// Connect inputs for a presence hold, bundled so the hold helpers stay within the parameter-count limit.
private struct PresenceHoldContext {
    let formatter: any CLIFormatter
    let environment: AppEnvironment
    let account: DuckoCore.Account
    let password: String
}

/// Holds a broadcast presence open for an explicit lifetime so subscribers observe it as durable state, then
/// clean-disconnects (which sends `unavailable`). The interrupt arbiter/consumer is started *before* `connect`,
/// and the hold work runs as an *unstructured* task so a SIGINT/SIGTERM during a slow or wedged connect triggers
/// the bounded clean-teardown immediately rather than waiting for the connect to unblock. Natural `--for` expiry
/// exits `0`; an interrupt throws `ExitCode(130|143)` after the bounded clean disconnect so normal unwinding runs.
private func runPresenceHold(
    lifetime: PresenceHoldLifetime,
    context: PresenceHoldContext,
    status: PresenceService.PresenceStatus,
    message: String?
) async throws {
    let monitor = InterruptMonitor.install()
    defer { monitor.cancel() }
    let arbiter = HoldArbiter()

    // Sole consumer of the signal stream for the whole lifetime — including teardown, so a second signal can
    // force an immediate hard exit. Bind the Sendable stream so the task doesn't capture the whole monitor.
    let signals = monitor.signals
    let signalTask = Task {
        for await signo in signals where await arbiter.recordSignal(signo) {
            Foundation.exit(exitCode(forSignal: signo))
        }
    }
    defer { signalTask.cancel() }

    // Unstructured so the arbiter can resolve the outcome and teardown can proceed without awaiting a stuck
    // connect; the watcher reports the work's natural end or failure to the arbiter.
    let workTask = Task { try await performHoldWork(lifetime: lifetime, context: context, status: status, message: message) }
    defer { workTask.cancel() }
    let workWatcher = Task {
        do {
            try await workTask.value
            await arbiter.recordExpiry()
        } catch is CancellationError {
        } catch {
            await arbiter.recordWorkFailed()
        }
    }
    defer { workWatcher.cancel() }

    var endReason = HoldEndReason.expired
    for await reason in arbiter.ends {
        endReason = reason
        break
    }
    await boundedTeardown(environment: context.environment, arbiter: arbiter)

    switch endReason {
    case .expired:
        return
    case .workFailed:
        try await workTask.value // rethrows the original error (connect/apply failure)
    case let .interrupted(signo):
        printToStandardError("Interrupted, disconnecting…")
        throw ExitCode(exitCode(forSignal: signo))
    }
}

/// Connects, broadcasts the held status, then suspends for the lifetime. `--for` returns when the window
/// elapses; `--keep-alive` only ends by cancellation (once the arbiter resolves via a signal).
private func performHoldWork(
    lifetime: PresenceHoldLifetime,
    context: PresenceHoldContext,
    status: PresenceService.PresenceStatus,
    message: String?
) async throws {
    let env = context.environment
    let accountID = context.account.id
    try await connectStored(env, accountID: accountID, password: context.password)
    try await waitForConnected(accountID: accountID, environment: env)
    await applyPresence(status, message: message, environment: env, accountID: accountID)
    print(context.formatter.formatPresence(jid: context.account.jid, status: status.rawValue, message: message))
    // stdout is block-buffered when piped (no TTY); flush so the set-status line is observable during the hold
    // rather than only on exit.
    fflush(stdout)
    switch lifetime {
    case let .bounded(duration):
        printToStandardError("Holding presence until the window elapses (Ctrl-C to stop early)…")
        try await Task.sleep(for: duration)
    case .keepAlive:
        printToStandardError("Holding presence until interrupted (Ctrl-C to stop)…")
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

/// Marks teardown started (so a further signal hard-exits) and clean-disconnects within a bounded window.
private func boundedTeardown(environment: AppEnvironment, arbiter: HoldArbiter) async {
    await arbiter.beginTeardown()
    await environment.accountService.disconnectAll(within: .seconds(3))
}
