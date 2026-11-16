import DuckoXMPP
import Foundation
import Testing

/// Signs in to a server that offers the XEP-0480 upgrade to SCRAM-SHA-256 while the account holds only SCRAM-SHA-1. It
/// stays outside `DuckoIntegrationTests`, whose gate and serialization cover the accounts of another server. It drives
/// bare clients, so nothing else touches this server.
@Suite(.enabled(if: TestCredentials.isSASLUpgradeTestingEnabled, "Needs the DUCKO_TEST_SASL_UPGRADE_* variables"))
struct SASLUpgradeTests {
    @Test func `A SCRAM-SHA-1 account is upgraded, and signs in with SCRAM-SHA-256 next`() async throws {
        try await Self.resetServerState()

        // Before the upgrade the server offers only SCRAM-SHA-1, so this sign-in uses it and asks for the upgrade.
        #expect(try await Self.signIn() == "SCRAM-SHA-1-PLUS")
        // The server offers SCRAM-SHA-256 once it holds the credential that the first sign-in's hash created.
        #expect(try await Self.signIn() == "SCRAM-SHA-256-PLUS")
    }

    /// Signs in with a new client and returns the SCRAM mechanism whose server signature it verified. A client cannot
    /// connect again after `disconnect`, so each sign-in gets its own.
    private static func signIn() async throws -> String? {
        let credential = TestCredentials.saslUpgrade
        let jid = try #require(BareJID.parse(credential.jid))
        let username = try #require(jid.localPart)
        let port = try #require(TestCredentials.saslUpgradePort)
        let client = XMPPClient(domain: jid.domainPart, credentials: .init(username: username, password: credential.password))
        do {
            try await client.connect(host: jid.domainPart, port: port)
        } catch {
            await client.disconnect()
            throw error
        }
        let mechanism = client.verifiedSCRAMMechanism
        await client.disconnect()
        return mechanism
    }

    /// Runs the reset command, which makes the server offer the upgrade again. Its output goes to files, because a
    /// child that outlives the shell, such as `ssh`, could keep a pipe open and block reading it past the wait's bound.
    private static func resetServerState() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ducko-sasl-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appending(path: "stdout")
        let stderrURL = directory.appending(path: "stderr")
        FileManager.default.createFile(atPath: stdoutURL.path(percentEncoded: false), contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path(percentEncoded: false), contents: nil)

        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", TestCredentials.saslUpgradeResetCommand]
        process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()

        let exited = await CLIProcess.waitForProcessExit(process, timeout: .seconds(60))
        if !exited {
            await CLIProcess.killProcess(process)
        }
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        try #require(exited, "The reset command did not finish within 60 seconds: \(stderr)")
        try #require(
            process.terminationStatus == 0,
            "The reset command exited with status \(process.terminationStatus): \(stderr)"
        )
    }
}
