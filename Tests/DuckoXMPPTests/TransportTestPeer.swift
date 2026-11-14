import Foundation
import Testing
@testable import DuckoXMPP

final class TransportTestPeer {
    private struct Endpoint: Decodable {
        let port: UInt16
        let rootPath: String
        let fingerprint: String
        let expiry: Double
        let protocolVersion: String?
        let certificate: String?
        let key: String?
    }

    private let process: Process
    private let output: Pipe
    let port: UInt16
    let anchor: Data
    let fingerprint: String
    let expiry: Date
    let protocolVersion: String?
    /// The leaf certificate and its private key as PEM, from a peer that only creates them.
    let certificate: String?
    let key: String?

    init(mode: String, scriptName: String = "tls-peer") throws {
        let script = try #require(Bundle.module.url(forResource: scriptName, withExtension: "py", subdirectory: "Fixtures"))
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DUCKO_TLS_PYTHON"] ?? "/usr/bin/python3")
        process.arguments = [script.path, mode]
        if let fixtures = ProcessInfo.processInfo.environment["DUCKO_TLS_FIXTURE_DIRECTORY"] {
            process.arguments?.append(fixtures)
        }
        process.standardOutput = output
        try process.run()
        do {
            let endpoint = try JSONDecoder().decode(Endpoint.self, from: output.fileHandleForReading.availableData)
            self.anchor = try Data(contentsOf: URL(fileURLWithPath: endpoint.rootPath))
            self.port = endpoint.port
            self.fingerprint = endpoint.fingerprint
            self.expiry = Date(timeIntervalSince1970: endpoint.expiry)
            self.protocolVersion = endpoint.protocolVersion
            self.certificate = endpoint.certificate
            self.key = endpoint.key
            self.process = process
            self.output = output
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    /// Decodes the next JSON line the peer prints after its endpoint.
    func nextValue<Value: Decodable>(_: Value.Type) throws -> Value {
        try JSONDecoder().decode(Value.self, from: output.fileHandleForReading.availableData)
    }

    func expectSuccess() async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !process.isRunning else { throw XMPPClientError.timeout }
        #expect(process.terminationStatus == 0)
    }

    func stop() async {
        if process.isRunning { process.terminate() }
        let deadline = ContinuousClock.now + .seconds(2)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }
}
