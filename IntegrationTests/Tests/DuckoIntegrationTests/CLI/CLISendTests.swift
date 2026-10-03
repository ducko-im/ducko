import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLISendTests {
        @Test
        @MainActor func `ducko send delivers a message to bob's REPL`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob
                try await aliceCLI.seedAccount(alice)

                let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                await bobCLI.addCleanup { await bobREPL.terminate() }

                let body = "msg-\(UUID().uuidString.prefix(8))"
                let sent = try await aliceCLI.run([
                    "send", bob.jid, body, "--output", "plain"
                ])
                #expect(sent.exitCode == 0)

                _ = try await bobREPL.waitForOutput(containing: body, timeout: TestTimeout.replOutput)
            }
        }

        @Test
        @MainActor func `bidirectional REPL exchange round-trips messages`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                await bobCLI.addCleanup { await bobREPL.terminate() }

                let outbound = "msg-\(UUID().uuidString.prefix(8))"
                let reply = "msg-\(UUID().uuidString.prefix(8))"

                try await aliceREPL.send("send \(bob.jid) \(outbound)")
                _ = try await bobREPL.waitForOutput(containing: outbound, timeout: TestTimeout.replOutput)

                try await bobREPL.send("send \(alice.jid) \(reply)")
                _ = try await aliceREPL.waitForOutput(containing: reply, timeout: TestTimeout.replOutput)
            }
        }

        @Test
        @MainActor func `ducko send --file delivers a file to bob`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let fileNonce = UUID().uuidString
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ducko-inttest-fixture-\(fileNonce).txt", isDirectory: false)
                let payload = String(repeating: "ducko-inttest-\(UUID().uuidString)\n", count: 64)
                try payload.write(to: fileURL, atomically: true, encoding: .utf8)
                await aliceCLI.addCleanup { try? FileManager.default.removeItem(at: fileURL) }

                try await aliceCLI.seedAccount(alice)

                let bobREPL = try await REPLSession.start(
                    cli: bobCLI, credentials: bob, arguments: ["--output", "plain"]
                )
                await bobCLI.addCleanup { await bobREPL.terminate() }

                // Without `--method`, a file goes by HTTP File Upload
                // (XEP-0363) and the resulting URL is sent as a regular
                // chat message; bob's REPL surfaces it via
                // `formatIncomingMessage` rather than `formatFileOffer`.
                // The asserted substring is the file's UUID nonce —
                // present in the upload-server URL — so the assertion
                // proves end-to-end delivery without depending on which
                // formatter handler ran.
                let sent = try await aliceCLI.run([
                    "send", "--file", fileURL.path, bob.jid,
                    "--output", "plain"
                ], timeout: TestTimeout.fileTransfer)
                #expect(sent.exitCode == 0)

                _ = try await bobREPL.waitForOutput(
                    containing: fileNonce,
                    timeout: TestTimeout.fileTransfer
                )
            }
        }

        @Test
        @MainActor func `ducko send --method jingle drives accept to completion via bob's full JID`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let fileNonce = UUID().uuidString
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ducko-inttest-jingle-\(fileNonce).txt", isDirectory: false)
                let payload = String(repeating: "ducko-jingle-\(UUID().uuidString)\n", count: 64)
                try payload.write(to: fileURL, atomically: true, encoding: .utf8)
                await aliceCLI.addCleanup { try? FileManager.default.removeItem(at: fileURL) }

                try await aliceCLI.seedAccount(alice)

                // Bob's REPL (plain output) surfaces both his bound full JID (connection event) and the
                // incoming file offer. The full JID — with resource — names the one session the offer goes to,
                // and bob's own connection event is the only CLI surface that exposes it. Bob (rather than
                // dave) is used because he is part of the base credential set, so this test runs unconditionally
                // rather than skipping behind `isDaveAvailable`; a Jingle transfer routes by full-JID IQ
                // regardless of subscription and does not mutate any roster baseline, so reusing bob is safe.
                let bobREPL = try await REPLSession.start(
                    cli: bobCLI, credentials: bob, arguments: ["--output", "plain"]
                )
                await bobCLI.addCleanup { await bobREPL.terminate() }

                let banner = try await bobREPL.waitForOutput(containing: "connected as ", timeout: TestTimeout.connect)
                let bobFullJID = try #require(Self.parseConnectedJID(from: banner))

                // `send --method jingle` does not return until the receiver `/accept`s
                // (`awaitTransportReady`), so run it concurrently and drive bob's `/accept` before awaiting
                // alice's result — a sequential send would hang until the CLI timeout.
                async let sendResult = aliceCLI.run(
                    ["send", "--method", "jingle", bobFullJID, "--file", fileURL.path, "--output", "plain"],
                    timeout: TestTimeout.fileTransfer
                )

                _ = try await bobREPL.waitForOutput(containing: "[File offer]", timeout: TestTimeout.fileTransfer)
                try await bobREPL.send("/accept")

                let sent = try await sendResult
                #expect(sent.exitCode == 0)

                // Bob's long-lived REPL surfaces the receiver-side completion (`jingleFileTransferCompleted`).
                _ = try await bobREPL.waitForOutput(
                    containing: "Transfer completed",
                    timeout: TestTimeout.fileTransfer
                )
            }
        }

        @Test
        @MainActor func `REPL /senddirect says what stops a send and finds the contact's device by itself`() async throws {
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let fileNonce = UUID().uuidString
                let fileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ducko-inttest-senddirect-\(fileNonce).txt", isDirectory: false)
                try "ducko-senddirect-\(fileNonce)\n".write(to: fileURL, atomically: true, encoding: .utf8)
                await aliceCLI.addCleanup { try? FileManager.default.removeItem(at: fileURL) }

                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice, arguments: ["--output", "plain"])
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                // A file that is not there, and a contact with no device online, are said at the prompt.
                try await aliceREPL.send("/senddirect \(bob.jid) /nonexistent/\(fileNonce).txt")
                _ = try await aliceREPL.waitForOutput(containing: "File not found")
                try await aliceREPL.send("/senddirect \(bob.jid) \(fileURL.path)")
                let refused = try await aliceREPL.waitForOutput(containing: "no device online")
                #expect(!refused.contains("Use /transfers"))

                let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob, arguments: ["--output", "plain"])
                await bobCLI.addCleanup { await bobREPL.terminate() }

                // Only bob's bare JID is given: his device is found by asking the sessions his presence announces.
                // That presence takes a moment to arrive after he connects, so the command is tried again until it
                // goes through.
                var isSending = false
                for _ in 0 ..< 10 where !isSending {
                    let cursor = await aliceREPL.cursor()
                    try await aliceREPL.send("/senddirect \(bob.jid) \(fileURL.path)")
                    let output = try await aliceREPL.waitForOutput(containingAnyOf: ["Use /transfers", "no device online"], after: cursor)
                    isSending = output.dropFirst(cursor).contains("Use /transfers")
                    if !isSending {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try #require(isSending)

                _ = try await bobREPL.waitForOutput(containing: "[File offer]", timeout: TestTimeout.fileTransfer)
                try await bobREPL.send("/accept")
                _ = try await bobREPL.waitForOutput(containing: "Transfer completed", timeout: TestTimeout.fileTransfer)
            }
        }

        // MARK: - Helpers

        /// Extracts the bound full JID from a `PlainFormatter` connection-event line
        /// (`connected as <jid>`). The CLI exposes a peer's resource nowhere else — roster, presence,
        /// message, and file-offer output are all bare JIDs. Splits on `\.isNewline` rather than `"\n"`
        /// because the REPL's PTY emits `\r\n`, which Swift treats as a single grapheme-cluster Character —
        /// `split(separator: "\n")` (or `== "\r"`/`"\n"`) never matches it, fusing the "connected as" line
        /// to all subsequent output and yielding a multi-line garbage JID the Jingle initiate can't route to.
        private static func parseConnectedJID(from output: String) -> String? {
            for line in output.split(whereSeparator: \.isNewline) {
                guard let range = line.range(of: "connected as ") else { continue }
                let jid = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !jid.isEmpty { return jid }
            }
            return nil
        }
    }
}
