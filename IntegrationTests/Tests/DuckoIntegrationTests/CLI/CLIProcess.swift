import Darwin
import Foundation
import Logging

private let log = Logger(label: "im.ducko.integrationtests.cli")

/// Captured stdout, stderr, and exit code from a one-shot `ducko` invocation.
///
/// `terminationReason` disambiguates `exitCode`: Foundation's
/// `Process.terminationStatus` returns the OS exit code on a normal exit but
/// the *signal number* on an uncaught signal (e.g. `13` could be exit 13 OR
/// SIGPIPE). Callers that surface this in errors should print both fields.
struct CLIOutput {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let terminationReason: Process.TerminationReason
}

/// Spawns the debug-built `ducko` binary as a child process and exposes a
/// scoped helper that mirrors `TestHarness.withHarness` lifecycle semantics.
///
/// Each `CLIProcess` carries a `DUCKO_PROFILE` so its credentials, transcripts,
/// and SwiftData metadata are isolated under
/// `~/Library/Application Support/Ducko-Dev-<profile>/` and torn down when the
/// helper closure returns.
///
/// State held by the actor is the env dictionary passed to spawned processes
/// plus the LIFO `cleanupActions` queue that REPL sessions register against;
/// public methods are `async` so callers do not need to think about isolation.
actor CLIProcess {
    nonisolated let profile: String
    nonisolated let environment: [String: String]
    private var cleanupActions: [@Sendable () async -> Void] = []

    init(profile: String) {
        self.profile = profile

        // Inherit only the environment variables the CLI needs to find Foundation
        // bundles, locales, and the user's home directory; everything else stays
        // unset so a stray DUCKO_USE_KEYCHAIN=1 in the developer's shell does not
        // route test passwords into the macOS Keychain.
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "DUCKO_PROFILE": profile
        ]
        for key in ["HOME", "PATH", "LANG", "LC_ALL"] {
            if let value = parent[key] {
                env[key] = value
            }
        }
        self.environment = env
    }

    /// Path to the debug-built CLI binary. Resolved relative to this file via
    /// `#filePath` so checkout location does not matter; mirrors the walk-up
    /// pattern used by `TestCredentials`.
    static var binaryPath: URL {
        // CLIProcess.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/CLI/CLIProcess.swift
        // The debug CLI binary lives at:
        //   .build/debug/DuckoCLI
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CLI
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("DuckoCLI")
    }

    /// Suite-level skip predicate — CLI tests need a debug-built binary on disk.
    static var binaryExists: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath.path)
    }

    // MARK: - Lifecycle

    /// Runs `body` with a fresh `CLIProcess`, awaiting profile cleanup and any
    /// registered REPL terminations on both success and failure paths. Mirrors
    /// `TestHarness.withHarness` since Swift `defer` cannot await.
    static func withProcess<T: Sendable>(
        profile: String? = nil,
        _ body: sending (CLIProcess) async throws -> T
    ) async throws -> T {
        let resolvedProfile = profile ?? "inttest-\(UUID().uuidString.prefix(8))"
        let cli = CLIProcess(profile: resolvedProfile)
        do {
            let result = try await body(cli)
            await cli.tearDown()
            return result
        } catch {
            await cli.tearDown()
            throw error
        }
    }

    /// Runs `body` with a pair of fresh `CLIProcess` instances. Profile names
    /// embed the labels (default `alice`/`bob`) so per-process directories are
    /// distinguishable in the developer's `Application Support` tree when a
    /// test crashes mid-flight; the random suffix keeps runs isolated.
    /// Inlines the teardown loop instead of nesting two `withProcess` calls
    /// because passing a closure that captures a `sending` parameter to
    /// another `sending` parameter trips Swift 6 strict concurrency
    /// (`SendingClosureRisksDataRace`).
    static func withProcessPair<T: Sendable>(
        aliceLabel: String = "alice",
        bobLabel: String = "bob",
        _ body: sending (CLIProcess, CLIProcess) async throws -> T
    ) async throws -> T {
        let aliceCLI = CLIProcess(profile: "inttest-\(aliceLabel)-\(UUID().uuidString.prefix(8))")
        let bobCLI = CLIProcess(profile: "inttest-\(bobLabel)-\(UUID().uuidString.prefix(8))")
        do {
            let result = try await body(aliceCLI, bobCLI)
            await bobCLI.tearDown()
            await aliceCLI.tearDown()
            return result
        } catch {
            await bobCLI.tearDown()
            await aliceCLI.tearDown()
            throw error
        }
    }

    /// Appends a cleanup action; actions run in reverse order during teardown.
    func addCleanup(_ action: @escaping @Sendable () async -> Void) {
        cleanupActions.append(action)
    }

    // MARK: - Spawning

    /// Runs `ducko <arguments>` to completion and returns its captured output.
    /// Throws `TestHarnessError.binaryMissing` if the debug binary is absent
    /// and `TestHarnessError.timeout` if the process does not exit in time
    /// even after a SIGTERM/SIGKILL escalation.
    func run(
        _ arguments: [String],
        stdin: String? = nil,
        timeout: Duration = TestTimeout.cliCommand
    ) async throws -> CLIOutput {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestHarnessError.binaryMissing(path: binary.path)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()

        if let stdin {
            try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Capture pipes on detached tasks so a stuck child doesn't deadlock
        // waitUntilExit by filling the pipe buffer.
        let stdoutTask = Task.detached { (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data() }
        let stderrTask = Task.detached { (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data() }

        let exited = await Self.waitForProcessExit(process, timeout: timeout)
        if !exited {
            await Self.killProcess(process)
            // Drain reader tasks before throwing so they don't outlive this
            // function holding open pipe fds. Once `killProcess` reaps the
            // child, the pipe write ends close and `readToEnd()` returns.
            _ = await stdoutTask.value
            _ = await stderrTask.value
            log.warning("CLI invocation timed out: ducko \(Self.redactArguments(arguments).joined(separator: " "))")
            throw TestHarnessError.timeout
        }

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value

        // Capture `terminationReason` alongside `terminationStatus` so a child
        // killed by SIGPIPE (the bob CLI `account add` flake — R6) is not
        // indistinguishable from a clean `exit(13)`.
        let reason = process.terminationReason
        let status = process.terminationStatus
        if reason == .uncaughtSignal {
            log.warning("""
            CLI child killed by signal \(status): \
            ducko \(Self.redactArguments(arguments).joined(separator: " ")) \
            (pid=\(process.processIdentifier))
            """)
        }

        return CLIOutput(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: status,
            terminationReason: reason
        )
    }

    /// Spawns `ducko <arguments>` without blocking on exit and returns a handle
    /// that can signal the child, await a readiness substring on its captured
    /// stdout, and observe its `terminationStatus`/`terminationReason` after
    /// exit. Unlike `run`, this is the surface for tests that must send a signal
    /// mid-run. Registers a cleanup action so a still-running child (e.g. a
    /// `--keep-alive` hold) is killed and drained even if the test throws before
    /// `awaitExit`.
    func spawn(_ arguments: [String]) async throws -> CLISpawnHandle {
        let binary = Self.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestHarnessError.binaryMissing(path: binary.path)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let handle = CLISpawnHandle(
            process: process,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
        addCleanup { await handle.terminateIfRunning() }
        return handle
    }

    /// Throws `TestHarnessError.nonZeroExit` unless `output` exited cleanly (not
    /// a signal kill). Shared by the seeding helpers so a seed regression
    /// surfaces at seed time rather than downstream.
    private func requireCleanExit(_ output: CLIOutput) throws -> CLIOutput {
        guard output.exitCode == 0, output.terminationReason == .exit else {
            throw TestHarnessError.nonZeroExit(
                code: output.exitCode,
                reason: output.terminationReason,
                stdout: output.stdout,
                stderr: output.stderr
            )
        }
        return output
    }

    /// Adds an account to this profile via `ducko account add` and throws on
    /// non-zero exit. Mirrors the seeding `REPLSession.start` does internally
    /// so call sites that don't spawn a REPL share the same code path.
    @discardableResult
    func seedAccount(_ credential: TestCredentials.Credential) async throws -> CLIOutput {
        let output = try await run([
            "account", "add", credential.jid, "--password", credential.password
        ])
        return try requireCleanExit(output)
    }

    /// Adds an account pointing at an unreachable endpoint via
    /// `ducko account add … --no-connect` so a failing or wedged connect can be
    /// seeded without `account add`'s connect-to-validate rolling it back.
    /// Throws on non-zero exit so a `--no-connect` regression — e.g. it
    /// accidentally still connecting and failing — surfaces at seed time.
    @discardableResult
    func seedUnreachableAccount(jid: String, host: String, port: UInt16) async throws -> CLIOutput {
        let output = try await run([
            "account", "add", jid,
            "--password", "seed-unreachable",
            "--host", host,
            "--port", String(port),
            "--no-connect"
        ])
        return try requireCleanExit(output)
    }

    /// Binds a TCP socket to `127.0.0.1:0`, reads the kernel-assigned port, then
    /// closes the socket and returns the now-closed port. A connect to it
    /// fast-fails with `ECONNREFUSED`. Throws `LoopbackTCPSocketError` on the
    /// improbable setup failure so a fixture failure points at socket setup
    /// rather than surfacing later as confusing CLI-connect behavior. Accepts a
    /// tiny rebind race: another process could claim the freed port.
    static func reserveClosedLoopbackPort() throws -> UInt16 {
        let bound = try bindLoopbackTCPSocket()
        defer { close(bound.fd) }
        return bound.port
    }

    /// Removes the on-disk profile directory under
    /// `~/Library/Application Support/Ducko-Dev-<profile>/`. Idempotent.
    func cleanupProfileDirectory() async {
        await Self.removeProfileDirectory(profile: profile)
    }

    /// Profile-directory removal as a free static so other test harnesses
    /// (e.g. `AppAccessor`) can share the implementation rather than copy it.
    nonisolated static func removeProfileDirectory(profile: String) async {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ducko-Dev-\(profile)", isDirectory: true)
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Profile directory was never created — expected for tests that
            // don't run any CLI invocation.
        } catch {
            log.warning("Failed to remove profile directory \(url.path): \(error.localizedDescription)")
        }
    }

    // MARK: - Process lifecycle helpers

    /// Polls `process.isRunning` until exit or timeout. Returns `true` on
    /// natural exit, `false` on timeout. Cooperative-cancellation friendly,
    /// unlike `Task.detached { process.waitUntilExit() }.value` which holds a
    /// thread until the process completes regardless of cancellation.
    nonisolated static func waitForProcessExit(
        _ process: Process,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !process.isRunning { return true }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Outer cancellation (e.g. from a containing `runWithTimeout`'s
                // `cancelAll()` once the soft deadline fires) — return current
                // process state immediately so the caller can unwind. Without
                // this, swallowing the cancellation would busy-spin the loop
                // until the original deadline expires.
                return !process.isRunning
            }
        }
        return !process.isRunning
    }

    /// Escalates from SIGTERM to SIGKILL with grace periods between, then
    /// awaits the final exit. Used on timeout paths where the child has
    /// already missed its deadline.
    nonisolated static func killProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        if await waitForProcessExit(process, timeout: .seconds(2)) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = await waitForProcessExit(process, timeout: .seconds(2))
    }

    /// Redacts the value following `--password` so timeout warning logs do not
    /// leak test credentials. CLAUDE.md privacy policy bars passwords in
    /// `warning`-level logs.
    nonisolated static func redactArguments(_ arguments: [String]) -> [String] {
        var redacted: [String] = []
        var redactNext = false
        for arg in arguments {
            if redactNext {
                redacted.append("<redacted>")
                redactNext = false
            } else {
                redacted.append(arg)
                if arg == "--password" { redactNext = true }
            }
        }
        return redacted
    }

    // MARK: - Teardown

    private func tearDown() async {
        // Bound each cleanup so a stuck `REPLSession.terminate` (e.g. reader
        // wedged on a POSIX read) cannot hang the suite.
        for action in cleanupActions.reversed() {
            await runIntegrationCleanup(action, timeout: .seconds(5), label: "CLI")
        }
        cleanupActions.removeAll()
        await cleanupProfileDirectory()
    }
}

/// Handle over a non-blocking `CLIProcess.spawn` child. Buffers stdout/stderr on detached drain tasks so a
/// test can await a deterministic readiness substring (the set-status line) before sending a signal, then
/// reap the child and read its `terminationStatus`/`terminationReason`. Exit-waiting and kill-escalation reuse
/// `CLIProcess`'s `nonisolated static` helpers.
actor CLISpawnHandle {
    private let process: Process
    nonisolated let pid: Int32
    private let stdoutBuffer: OutputBuffer
    private let stderrBuffer: OutputBuffer
    private let stdoutReader: Task<Void, Never>
    private let stderrReader: Task<Void, Never>
    private var reaped = false

    init(process: Process, stdout: FileHandle, stderr: FileHandle) {
        self.process = process
        self.pid = process.processIdentifier
        let outBuffer = OutputBuffer()
        let errBuffer = OutputBuffer()
        self.stdoutBuffer = outBuffer
        self.stderrBuffer = errBuffer
        self.stdoutReader = Task.detached(priority: .utility) { await Self.drain(stdout, into: outBuffer) }
        self.stderrReader = Task.detached(priority: .utility) { await Self.drain(stderr, into: errBuffer) }
    }

    /// Sends `signo` (e.g. `SIGINT`) to the child via POSIX `kill`.
    func sendSignal(_ signo: Int32) {
        kill(pid, signo)
    }

    /// Polls captured stdout for `substring`, returning the snapshot when found — the deterministic readiness
    /// signal that replaces a fixed sleep before signalling the child.
    @discardableResult
    func waitForStdout(
        containing substring: String,
        timeout: Duration = TestTimeout.cliCommand
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await stdoutBuffer.snapshotIfContains(substring) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let snapshot = await stdoutBuffer.snapshotIfContains(substring) {
            return snapshot
        }
        throw TestHarnessError.timeout
    }

    /// Waits until the child's stderr contains `substring` and returns stderr as captured so far, as `waitForStdout`
    /// does for stdout.
    func waitForStderr(
        containing substring: String,
        timeout: Duration = TestTimeout.cliCommand
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await stderrBuffer.snapshotIfContains(substring) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let snapshot = await stderrBuffer.snapshotIfContains(substring) {
            return snapshot
        }
        throw TestHarnessError.timeout
    }

    /// Waits for the child to exit (escalating SIGTERM→SIGKILL on timeout), drains the readers, and returns
    /// its captured output and `terminationStatus`/`terminationReason`.
    func awaitExit(timeout: Duration = TestTimeout.cliCommand) async throws -> CLIOutput {
        let exited = await CLIProcess.waitForProcessExit(process, timeout: timeout)
        if !exited {
            await CLIProcess.killProcess(process)
            await drainReaders()
            throw TestHarnessError.timeout
        }
        reaped = true
        await drainReaders()
        return await CLIOutput(
            stdout: stdoutBuffer.snapshot(),
            stderr: stderrBuffer.snapshot(),
            exitCode: process.terminationStatus,
            terminationReason: process.terminationReason
        )
    }

    /// Cleanup hook: kills and drains a still-running child so a held process can't survive `withProcess`
    /// teardown. No-op once `awaitExit` has reaped the child.
    func terminateIfRunning() async {
        if reaped { return }
        await CLIProcess.killProcess(process)
        await drainReaders()
    }

    private func drainReaders() async {
        _ = await stdoutReader.value
        _ = await stderrReader.value
    }

    private static func drain(_ handle: FileHandle, into buffer: OutputBuffer) async {
        while true {
            let data = handle.availableData
            if data.isEmpty { return }
            await buffer.append(String(decoding: data, as: UTF8.self))
        }
    }
}
