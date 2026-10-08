import DuckoData
import Foundation
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/debug/DuckoCLI")
        process.arguments = arguments
        let parent = ProcessInfo.processInfo.environment
        process.environment = ["HOME": parent["HOME"] ?? "", "PATH": parent["PATH"] ?? "", "DUCKO_PROFILE": name]
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = Task.detached { try stdout.fileHandleForReading.readToEnd() ?? Data() }
        let errors = Task.detached { try stderr.fileHandleForReading.readToEnd() ?? Data() }
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
}
