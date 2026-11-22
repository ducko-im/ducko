import Darwin
import DuckoData
import Foundation
import struct os.OSAllocatedUnfairLock
import SwiftData

/// A debug profile of its own under Application Support that the built CLI is run against, holding nothing of a real
/// profile.
@MainActor
struct ThrowawayProfile {
    struct Run {
        let output: String
        let errors: String
        let exitCode: Int32
        let reason: Process.TerminationReason
    }

    let directory: URL
    private let name: String

    init(named prefix: String) throws {
        self.name = "\(prefix)-\(UUID().uuidString)"
        self.directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Ducko-Dev-\(name)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: "im.ducko.dev.\(name)")
    }

    /// The store the CLI reads its accounts and conversations from.
    func makeStore() throws -> SwiftDataPersistenceStore {
        let configuration = ModelConfiguration(url: directory.appending(path: "default.store"))
        return try SwiftDataPersistenceStore(modelContainer: ModelContainer(for: ModelContainerFactory.schema, configurations: [configuration]))
    }

    /// Runs the built CLI in this profile with `input` on its standard input and waits for it to end. A run still
    /// going after 15 seconds is stopped, as is one whose wait is cut short.
    func run(_ arguments: [String], input: String = "") async throws -> Run {
        let (process, pipes) = try launch(arguments)
        let output = Self.readToEnd(pipes.stdout)
        let errors = Self.readToEnd(pipes.stderr)
        try await Self.supervising(process, readers: [output, errors]) {
            pipes.give(input)
            try pipes.stdin.fileHandleForWriting.close()
        }
        return try await Run(
            output: String(decoding: output.value, as: UTF8.self), errors: String(decoding: errors.value, as: UTF8.self),
            exitCode: process.terminationStatus, reason: process.terminationReason
        )
    }

    /// A standard stream of the CLI that a run watches.
    enum Stream {
        case output, errors
    }

    /// Runs the built CLI in this profile with `input` on its standard input, which stays open, until `stream` holds
    /// a whole line from `marker` on. `atMarker` then gets that stream so far, the CLI gets `signals` 10 ms apart, and
    /// the run ends when the CLI does. When the CLI ends, or 15 seconds pass, without such a line, the run stops it and
    /// throws `MarkerNotShown`. A CLI that doesn't end within 15 seconds of the signals is stopped, as is one whose run
    /// is cut short.
    func run(
        _ arguments: [String], input: String, until marker: String, in stream: Stream = .output, atMarker: (String) throws -> Void,
        thenSignals signals: [Int32]
    ) async throws -> Run {
        let (process, pipes) = try launch(arguments)
        let (watched, other) = stream == .output ? (pipes.stdout, pipes.stderr) : (pipes.stderr, pipes.stdout)
        defer { try? pipes.stdin.fileHandleForWriting.close() }
        let shown = OSAllocatedUnfairLock(initialState: Data())
        let watchedReader = Self.readToEnd(watched, showingIn: shown)
        let otherReader = Self.readToEnd(other)
        try await Self.supervising(process, readers: [watchedReader, otherReader]) {
            pipes.give(input)
            let deadline = ContinuousClock.now + .seconds(15)
            while true {
                let text = String(decoding: shown.withLock { $0 }, as: UTF8.self)
                if let range = text.range(of: marker), text[range.upperBound...].contains("\n") {
                    try atMarker(text)
                    break
                }
                guard process.isRunning, ContinuousClock.now < deadline else { throw MarkerNotShown(marker: marker, output: text) }
                try await Task.sleep(for: .milliseconds(10))
            }
            for (index, signo) in signals.enumerated() {
                if index > 0 { try await Task.sleep(for: .milliseconds(10)) }
                kill(process.processIdentifier, signo)
            }
        }
        let watchedText = try await String(decoding: watchedReader.value, as: UTF8.self)
        let otherText = try await String(decoding: otherReader.value, as: UTF8.self)
        let (output, errors) = stream == .output ? (watchedText, otherText) : (otherText, watchedText)
        return Run(output: output, errors: errors, exitCode: process.terminationStatus, reason: process.terminationReason)
    }

    /// Runs the built CLI in this profile with its standard output a pipe whose read end is closed before the CLI
    /// starts, and waits for it to end. A run still going after 15 seconds is stopped, as is one whose wait is cut
    /// short. The run's `output` is empty.
    func runWithClosedOutput(_ arguments: [String]) async throws -> Run {
        let process = makeProcess(arguments)
        let stdout = Pipe(), stderr = Pipe()
        try stdout.fileHandleForReading.close()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let errors = Self.readToEnd(stderr)
        try await Self.supervising(process, readers: [errors])
        return try await Run(
            output: "", errors: String(decoding: errors.value, as: UTF8.self), exitCode: process.terminationStatus, reason: process.terminationReason
        )
    }

    /// Runs `body` against the launched `process` and waits up to 15 seconds for the CLI to end. Whether that succeeds
    /// or throws, it then stops the CLI if it is still running and waits for `readers` to reach the end of its output,
    /// so neither the CLI nor a reader outlives the run. Only then does it return or rethrow.
    private static func supervising(
        _ process: Process, readers: [Task<Data, any Error>], _ body: () async throws -> Void = {}
    ) async throws {
        let outcome: Result<Void, any Error>
        do {
            try await body()
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        stop(process)
        for reader in readers {
            _ = await reader.result
        }
        try outcome.get()
    }

    /// Ends `process` if it is still running: a terminate signal first, which the CLI may trap to disconnect, then a
    /// kill when it has not ended 3 seconds later, so a CLI stuck in its teardown cannot hang the test.
    private static func stop(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = ContinuousClock.now + .seconds(3)
            while process.isRunning, ContinuousClock.now < deadline {
                usleep(10000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    struct MarkerNotShown: Error, CustomStringConvertible {
        let marker: String
        let output: String

        var description: String {
            "The CLI never showed \(marker). Its output: \(output)"
        }
    }

    /// The pipes of a launched CLI's standard streams.
    private struct Pipes {
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()

        /// Writes `input` to the CLI's standard input. A CLI that ends before reading all of it fails the write, which
        /// the run ignores: the CLI got what it read.
        func give(_ input: String) {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        }
    }

    /// Starts the built CLI in this profile with pipes for its standard streams.
    private func launch(_ arguments: [String]) throws -> (process: Process, pipes: Pipes) {
        let process = makeProcess(arguments)
        let pipes = Pipes()
        // A write to the CLI's standard input after it ended would otherwise end the whole test run with SIGPIPE.
        _ = fcntl(pipes.stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = pipes.stdout
        process.standardError = pipes.stderr
        process.standardInput = pipes.stdin
        try process.run()
        return (process, pipes)
    }

    /// The built CLI, to run in this profile with `arguments`.
    private func makeProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug/DuckoCLI")
        process.arguments = arguments
        let parent = ProcessInfo.processInfo.environment
        process.environment = ["HOME": parent["HOME"] ?? "", "PATH": parent["PATH"] ?? "", "DUCKO_PROFILE": name]
        return process
    }

    /// Reads `pipe` until the process closes it, adding each piece to `shown`, when given, as it arrives. The read
    /// blocks until then, so it runs on a dispatch thread: a cooperative thread held by each open pipe can starve the
    /// pool that the loopback server and this wait run on.
    private static func readToEnd(_ pipe: Pipe, showingIn shown: OSAllocatedUnfairLock<Data>? = nil) -> Task<Data, any Error> {
        let handle = pipe.fileHandleForReading
        return Task {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result {
                        guard let shown else { return try handle.readToEnd() ?? Data() }
                        while case let data = handle.availableData, !data.isEmpty {
                            shown.withLock { $0.append(data) }
                        }
                        return shown.withLock { $0 }
                    })
                }
            }
        }
    }
}
