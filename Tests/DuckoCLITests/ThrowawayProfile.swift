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
        let (stdout, stderr, stdin) = (pipes.stdout, pipes.stderr, pipes.stdin)
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = Self.readToEnd(stdout)
        let errors = Self.readToEnd(stderr)
        do {
            let deadline = ContinuousClock.now + .seconds(15)
            while process.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            process.terminate()
            process.waitUntilExit()
            _ = await output.result
            _ = await errors.result
            throw error
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return try await Run(
            output: String(decoding: output.value, as: UTF8.self), errors: String(decoding: errors.value, as: UTF8.self),
            exitCode: process.terminationStatus, reason: process.terminationReason
        )
    }

    /// Runs the built CLI in this profile with `input` on its standard input, which stays open, until its output holds
    /// a whole line from `marker` on. `atMarker` then gets the output so far, the CLI gets `signals` 10 ms apart, and
    /// the run ends when the CLI does. When the CLI ends, or 15 seconds pass, without such a line, the run stops it and
    /// throws `MarkerNotShown`. A CLI that doesn't end within 15 seconds of the signals is stopped.
    func run(
        _ arguments: [String], input: String, until marker: String, atMarker: (String) throws -> Void, thenSignals signals: [Int32]
    ) async throws -> Run {
        let (process, pipes) = try launch(arguments)
        let (stdout, stderr, stdin) = (pipes.stdout, pipes.stderr, pipes.stdin)
        defer {
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
        }
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        let shown = OSAllocatedUnfairLock(initialState: Data())
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                shown.withLock { $0.append(data) }
            }
        }
        let errors = Self.readToEnd(stderr)

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
        let exitDeadline = ContinuousClock.now + .seconds(15)
        while process.isRunning, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        stdout.fileHandleForReading.readabilityHandler = nil
        let rest = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        let output = shown.withLock { $0 } + rest
        return try await Run(
            output: String(decoding: output, as: UTF8.self), errors: String(decoding: errors.value, as: UTF8.self),
            exitCode: process.terminationStatus, reason: process.terminationReason
        )
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
    }

    /// Starts the built CLI in this profile with pipes for its standard streams.
    private func launch(_ arguments: [String]) throws -> (process: Process, pipes: Pipes) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug/DuckoCLI")
        process.arguments = arguments
        let parent = ProcessInfo.processInfo.environment
        process.environment = ["HOME": parent["HOME"] ?? "", "PATH": parent["PATH"] ?? "", "DUCKO_PROFILE": name]
        let pipes = Pipes()
        process.standardOutput = pipes.stdout
        process.standardError = pipes.stderr
        process.standardInput = pipes.stdin
        try process.run()
        return (process, pipes)
    }

    /// Reads `pipe` until the process closes it. The read blocks until then, so it runs on a dispatch thread: a
    /// cooperative thread held by each open pipe can starve the pool that the loopback server and this wait run on.
    private static func readToEnd(_ pipe: Pipe) -> Task<Data, any Error> {
        let handle = pipe.fileHandleForReading
        return Task {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try handle.readToEnd() ?? Data() })
                }
            }
        }
    }
}
