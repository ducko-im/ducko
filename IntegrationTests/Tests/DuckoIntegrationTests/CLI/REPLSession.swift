import Darwin
import Foundation
import Logging

private let replLog = Logger(label: "im.ducko.integrationtests.cli.repl")

/// Drives an interactive `ducko` REPL over a PTY pair so the CLI's
/// `isatty(STDIN_FILENO) == true` and `isatty(STDOUT_FILENO) == true`
/// checks (used by `OutputFormat.defaultForTerminal` and
/// `CredentialHelper`'s prompt fallback) succeed. Without the PTY, the
/// spawned process would treat the test runner as non-interactive and
/// either prompt for a password (no TTY to read from) or silently
/// default to `plain` output.
///
/// State on the actor is the spawned `Process`, the controller-end
/// (`/dev/ptmx`) PTY file descriptor, and the reader `Task`; the actor
/// isolation keeps `terminate()` from racing concurrent `send`/`waitForOutput`
/// calls. The replica-end (`/dev/pts/*`) fd is closed in the parent right
/// after `process.run()` so the controller end can receive EOF when the child
/// exits — without that, an unexpected child crash would wedge the reader
/// task in a blocking `read()`. Manual `terminate()` is mandatory because
/// `deinit` cannot await the child's exit.
actor REPLSession {
    private let process: Process
    private let ptmFD: Int32
    private let buffer: OutputBuffer
    private var readerTask: Task<Void, Never>?

    private init(process: Process, ptmFD: Int32) {
        self.process = process
        self.ptmFD = ptmFD
        let buffer = OutputBuffer()
        self.buffer = buffer
        self.readerTask = Task.detached(priority: .utility) {
            await Self.drain(ptmFD: ptmFD, into: buffer)
        }
    }

    // MARK: - Spawn

    /// Seeds the profile with `account add`, then spawns `ducko <arguments>`
    /// (default: `Interactive`). Without the seed, `Interactive.run` throws
    /// `CLIError.noAccounts` on a fresh `DUCKO_PROFILE` and the spawned REPL
    /// exits before printing the connection banner — every `start()` would
    /// otherwise time out. Returns once the connection banner appears; on a
    /// failed banner wait, the partial session is terminated before rethrow
    /// so callers don't have to.
    static func start(
        cli: CLIProcess,
        credentials: TestCredentials.Credential,
        arguments: [String] = []
    ) async throws -> REPLSession {
        try await cli.seedAccount(credentials)

        let session = try await spawn(cli: cli, arguments: arguments)
        do {
            // The REPL prints "Connected. Type 'help' for commands,
            // 'quit' to exit." once the bind+roster sync finishes.
            _ = try await session.waitForOutput(
                containing: "Connected. Type 'help' for commands",
                timeout: TestTimeout.connect
            )
        } catch {
            // Roll back the partial spawn so the caller's `addCleanup` registration
            // — which only runs on the success path — doesn't have to.
            await session.terminate()
            throw error
        }
        return session
    }

    private static func spawn(cli: CLIProcess, arguments: [String]) async throws -> REPLSession {
        let binary = CLIProcess.binaryPath
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw TestHarnessError.binaryMissing(path: binary.path)
        }

        let (ptmFD, ptsFD) = try openPTY()

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = cli.environment

        let stdin = FileHandle(fileDescriptor: ptsFD, closeOnDealloc: false)
        let stdout = FileHandle(fileDescriptor: ptsFD, closeOnDealloc: false)
        let stderr = FileHandle(fileDescriptor: ptsFD, closeOnDealloc: false)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            close(ptmFD)
            close(ptsFD)
            throw error
        }

        // Foundation has dup'd the replica fd into the child's stdio; closing
        // the parent's copy now lets the controller see EOF the moment the
        // child exits — even on an unexpected crash. Otherwise the reader
        // task wedges in `read()` until something else closes the fd.
        close(ptsFD)
        return REPLSession(process: process, ptmFD: ptmFD)
    }

    private static func openPTY() throws -> (ptm: Int32, pts: Int32) {
        let ptm = posix_openpt(O_RDWR | O_NOCTTY)
        guard ptm >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard grantpt(ptm) == 0, unlockpt(ptm) == 0 else {
            let saved = errno
            close(ptm)
            throw POSIXError(.init(rawValue: saved) ?? .EIO)
        }
        // `ptsname_r` is the documented thread-safe variant; `ptsname` returns
        // a pointer into a non-reentrant static buffer.
        var pathBuffer = [CChar](repeating: 0, count: 1024)
        let nameResult = pathBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            ptsname_r(ptm, buffer.baseAddress, buffer.count)
        }
        guard nameResult == 0 else {
            let saved = errno
            close(ptm)
            throw POSIXError(.init(rawValue: saved) ?? .EIO)
        }
        let nullIndex = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let ptsPath = String(decoding: pathBuffer[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let pts = open(ptsPath, O_RDWR | O_NOCTTY)
        guard pts >= 0 else {
            let saved = errno
            close(ptm)
            throw POSIXError(.init(rawValue: saved) ?? .EIO)
        }
        return (ptm, pts)
    }

    // MARK: - I/O

    /// Sends `command` followed by `\n` to the REPL.
    func send(_ command: String) throws {
        let line = command + "\n"
        try line.withCString { ptr in
            let length = strlen(ptr)
            var written = 0
            while written < length {
                let result = write(ptmFD, ptr.advanced(by: written), length - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += result
            }
        }
    }

    /// Polls the buffer for `substring`, returning the full snapshot when found.
    /// Mirrors `ConnectedAccount.waitForCondition`'s deadline-loop shape.
    @discardableResult
    func waitForOutput(
        containing substring: String,
        timeout: Duration = TestTimeout.replOutput
    ) async throws -> String {
        try await pollBuffer(timeout: timeout, label: "containing \"\(substring)\"") { buffer in
            await buffer.snapshotIfContains(substring)
        }
    }

    /// Polls the buffer for any of `substrings`, returning the full snapshot
    /// when one is found. Saves callers from hand-rolling a parallel
    /// deadline-loop helper for "wait for marker A or empty-state marker B".
    @discardableResult
    func waitForOutput(
        containingAnyOf substrings: [String],
        timeout: Duration = TestTimeout.replOutput
    ) async throws -> String {
        try await pollBuffer(timeout: timeout, label: "containing any of \(substrings)") { buffer in
            await buffer.snapshotIfContainsAny(substrings)
        }
    }

    /// Polls only the portion of the buffer **after** `cursor`, returning the
    /// full snapshot when one of `substrings` is found in the new content.
    /// Use to defend against broad markers (`[+]`/`[~]`/`[-]`) that may
    /// already be present from earlier commands in the same session — capture
    /// the cursor before sending the next command, then assert against new
    /// output past that point.
    @discardableResult
    func waitForOutput(
        containingAnyOf substrings: [String],
        after cursor: Int,
        timeout: Duration = TestTimeout.replOutput
    ) async throws -> String {
        try await pollBuffer(timeout: timeout, label: "containing any of \(substrings) after cursor \(cursor)") { buffer in
            await buffer.snapshotIfContainsAny(substrings, after: cursor)
        }
    }

    /// Polls the buffer after `cursor` for `substring` behind the first `marker` there, returning the full snapshot
    /// when it is found. Use where the terminal's echo of an earlier command holds `substring` too and may land after
    /// `cursor`: the echo comes before a marker that only the later command's output prints.
    @discardableResult
    func waitForOutput(
        containing substring: String,
        behind marker: String,
        after cursor: Int,
        timeout: Duration = TestTimeout.replOutput
    ) async throws -> String {
        try await pollBuffer(timeout: timeout, label: "containing \"\(substring)\" behind \"\(marker)\" after cursor \(cursor)") { buffer in
            await buffer.snapshotIfContains(substring, behind: marker, after: cursor)
        }
    }

    /// Returns the current accumulated REPL output.
    func snapshot() async -> String {
        await buffer.snapshot()
    }

    /// Returns the current buffer length so callers can pin a "wait only on
    /// new output past this point" cursor.
    func cursor() async -> Int {
        await buffer.cursor()
    }

    private func pollBuffer(
        timeout: Duration,
        label: @autoclosure () -> String,
        probe: (OutputBuffer) async -> String?
    ) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let snapshot = await probe(buffer) {
                return snapshot
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if let snapshot = await probe(buffer) {
            return snapshot
        }
        let final = await buffer.snapshot()
        replLog.warning("waitForOutput timeout (\(timeout)) waiting \(label()); buffer: \(final)")
        throw TestHarnessError.timeout
    }

    // MARK: - Teardown

    /// Politely shuts down the REPL: sends `quit\n`, waits up to 2 s for a
    /// clean exit, escalates to SIGTERM/SIGKILL on hang, then closes the
    /// controller fd so the reader task can drain on EOF and exit.
    func terminate() async {
        try? send("quit")

        let cleanExit = await CLIProcess.waitForProcessExit(process, timeout: .seconds(2))
        if !cleanExit {
            await CLIProcess.killProcess(process)
        }

        // Close the controller after the child exits so the reader's blocking
        // read() returns 0 and the reader task drains naturally — Task.cancel()
        // cannot unblock a thread sitting in a POSIX read.
        close(ptmFD)
        await readerTask?.value
        readerTask = nil
    }

    // MARK: - Private

    private static func drain(ptmFD: Int32, into buffer: OutputBuffer) async {
        let bufferSize = 4096
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { chunk.deallocate() }
        while true {
            let count = read(ptmFD, chunk, bufferSize)
            if count > 0 {
                let data = Data(bytes: chunk, count: count)
                let text = String(decoding: data, as: UTF8.self)
                await buffer.append(text)
            } else if count == 0 {
                return
            } else {
                if errno == EINTR { continue }
                return
            }
        }
    }
}

actor OutputBuffer {
    /// Cap on retained characters: enough for the longest assertion snapshot
    /// and the timeout-warning diagnostic, small enough that long-running
    /// REPL pollers don't grow memory linearly nor pay O(buffer-size) per
    /// substring scan.
    static let maxRetained = 64 * 1024

    private var contents = ""
    /// Characters dropped from the head so `cursor()` keeps returning a
    /// monotonic logical index — callers compare cursors taken across
    /// trim events.
    private var droppedCount = 0

    func append(_ chunk: String) {
        contents.append(chunk)
        let overflow = contents.count - Self.maxRetained
        guard overflow > 0 else { return }
        let dropIndex = contents.index(contents.startIndex, offsetBy: overflow)
        contents.removeSubrange(contents.startIndex ..< dropIndex)
        droppedCount += overflow
    }

    func snapshot() -> String {
        contents
    }

    func cursor() -> Int {
        droppedCount + contents.count
    }

    func snapshotIfContains(_ substring: String) -> String? {
        contents.contains(substring) ? contents : nil
    }

    func snapshotIfContainsAny(_ substrings: [String]) -> String? {
        substrings.contains(where: { contents.contains($0) }) ? contents : nil
    }

    func snapshotIfContains(_ substring: String, behind marker: String, after cursor: Int) -> String? {
        guard let tail = tail(after: cursor), let found = tail.range(of: marker) else { return nil }
        return tail[found.upperBound...].contains(substring) ? contents : nil
    }

    func snapshotIfContainsAny(_ substrings: [String], after cursor: Int) -> String? {
        guard let tail = tail(after: cursor) else { return nil }
        return substrings.contains(where: { tail.contains($0) }) ? contents : nil
    }

    /// The retained output behind `cursor`, or nil when there is none yet.
    private func tail(after cursor: Int) -> Substring? {
        // Cursor is a logical Character index including the dropped prefix
        // so emoji and multi-byte sequences don't shift the index. Translate
        // back into the retained tail.
        let effective = max(cursor - droppedCount, 0)
        guard contents.count > effective else { return nil }
        return contents.suffix(contents.count - effective)
    }
}
