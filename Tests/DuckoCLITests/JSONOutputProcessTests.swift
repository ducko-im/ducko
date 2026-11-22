import Foundation
import Testing
@testable import DuckoXMPP

/// How the CLI splits its output between standard output and standard error. Under `--output json`, every line on
/// standard output is one JSON record with a `type`, and prompts and guidance go to standard error.
@MainActor
struct JSONOutputProcessTests {
    @Test
    func `a command that fails on its arguments prints one error record beside the error on standard error`() async throws {
        let profile = try ThrowawayProfile(named: "json-invalid-jid")
        defer { profile.remove() }

        let run = try await profile.run(["send", "not a jid@@", "hi", "--output", "json"])

        let records = try jsonRecords(run.output)
        #expect(records == [["type": "error", "message": "Invalid JID: not a jid@@"]], Comment(rawValue: run.output))
        #expect(run.errors.contains("Error: Invalid JID"), Comment(rawValue: run.errors))
        #expect(run.reason == .exit && run.exitCode == 1)
    }

    @Test
    func `in plain output a failed command prints nothing on standard output`() async throws {
        let profile = try ThrowawayProfile(named: "plain-invalid-jid")
        defer { profile.remove() }

        let run = try await profile.run(["send", "not a jid@@", "hi", "--output", "plain"])

        #expect(run.output.isEmpty, Comment(rawValue: run.output))
        #expect(run.errors.contains("Error: Invalid JID"), Comment(rawValue: run.errors))
        #expect(run.exitCode == 1)
    }

    @Test
    func `an error record written to a closed pipe still ends with the error status, not a signal`() async throws {
        let profile = try ThrowawayProfile(named: "json-closed-output")
        defer { profile.remove() }

        let run = try await profile.runWithClosedOutput(["send", "not a jid@@", "hi", "--output", "json"])

        #expect(run.reason == .exit, Comment(rawValue: run.errors))
        #expect(run.exitCode == 1)
        #expect(run.errors.contains("Error: Invalid JID"), Comment(rawValue: run.errors))
    }

    @Test
    func `a command without an account prints one error record`() async throws {
        let profile = try ThrowawayProfile(named: "json-no-account")
        defer { profile.remove() }

        let run = try await profile.run(["send", "bob@example.com", "hi", "--output", "json"])

        let records = try jsonRecords(run.output)
        #expect(records == [["type": "error", "message": "No accounts configured. Run 'ducko account add <jid>' to add one."]], Comment(rawValue: run.output))
        #expect(run.exitCode == 1)
    }

    @Test
    func `a command whose server refuses the connection exits with an error record among its records`() async throws {
        let server = LoopbackXMPPServer(responder: NoReplies())
        let port = try await server.start()
        await server.stop()
        let profile = try ThrowawayProfile(named: "json-refused")
        defer { profile.remove() }
        try await profile.addLoopbackAccount(port: port)

        let run = try await profile.run(["send", "bob@example.com", "hi", "--output", "json"])

        let records = try jsonRecords(run.output)
        #expect(records.contains { $0["type"] == "error" }, Comment(rawValue: run.output + run.errors))
        #expect(run.reason == .exit && run.exitCode != 0)
    }

    @Test
    func `a command that fails validation prints nothing on standard output`() async throws {
        let profile = try ThrowawayProfile(named: "json-validation")
        defer { profile.remove() }

        let run = try await profile.run(["send", "bob@example.com", "--output", "json"])

        #expect(run.output.isEmpty, Comment(rawValue: run.output))
        #expect(run.errors.contains("Provide a message body or --file <path>"), Comment(rawValue: run.errors))
        #expect(run.exitCode != 0)
    }

    @Test
    func `a confirmation is one command result record`() async throws {
        try await withLoopbackServer(responder: BlockingResponder(), profile: "json-block") { _, profile in
            let run = try await profile.run(["blocklist", "add", "carol@example.com", "--output", "json"])

            #expect(run.exitCode == 0, Comment(rawValue: run.output + run.errors))
            let results = try jsonRecords(run.output).filter { $0["type"] == "command_result" }
            #expect(results == [["type": "command_result", "action": "block", "jid": "carol@example.com", "message": "Blocked carol@example.com."]],
                    Comment(rawValue: run.output))
        }
    }

    @Test
    func `account unregister asks on standard error and answers on standard output`() async throws {
        let profile = try ThrowawayProfile(named: "unregister-prompt")
        defer { profile.remove() }
        // The prompt comes before any connect, so the account's server is never reached.
        try await profile.addLoopbackAccount(port: 5222)

        let run = try await profile.run(["account", "unregister", "alice@example.com"], input: "no\n")

        #expect(run.output == "Cancelled.\n", Comment(rawValue: run.output))
        #expect(run.errors.contains("WARNING: This will permanently unregister alice@example.com from the server."), Comment(rawValue: run.errors))
        #expect(run.errors.contains("Type 'yes' to confirm:"), Comment(rawValue: run.errors))
    }

    @Test
    func `a command that runs synchronously still prints its output`() async throws {
        let profile = try ThrowawayProfile(named: "logs-path")
        defer { profile.remove() }

        let run = try await profile.run(["logs", "path"])

        #expect(run.exitCode == 0, Comment(rawValue: run.errors))
        #expect(run.output.hasSuffix("/Logs\n"), Comment(rawValue: run.output))
    }

    /// More input than a pipe holds, so the write is still under way when the CLI, which reads none of it, ends.
    @Test
    func `a run whose CLI ends without reading its input still returns the CLI's output`() async throws {
        let profile = try ThrowawayProfile(named: "unread-input")
        defer { profile.remove() }

        let run = try await profile.run(["logs", "path"], input: String(repeating: "x", count: 1 << 20))

        #expect(run.exitCode == 0, Comment(rawValue: run.errors))
        #expect(run.output.hasSuffix("/Logs\n"), Comment(rawValue: run.output))
    }

    @Test
    func `the REPL prints a record for each reply and its prompts and guidance on standard error`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "json-repl") { _, profile in
            let input = [
                "help", "/who", "/transfers", "/pref chatstates", "/pref chatstates on", "/pref chatstates maybe", "/pref bogus", "/bogus",
                "send alice@example.com", "/reply alice@example.com", "/sendfile notes.txt", "/senddirect notes.txt", "/unregister-account", "no",
                "quit"
            ].joined(separator: "\n") + "\n"

            let run = try await profile.run(["interactive", "--output", "json"], input: input)

            #expect(run.exitCode == 0, Comment(rawValue: run.output + run.errors))
            let records = try jsonRecords(run.output)
            #expect(records.count { $0["type"] == "help" } == 1, Comment(rawValue: run.output))
            #expect(records.contains { $0["type"] == "online_contacts_empty" }, Comment(rawValue: run.output))
            #expect(records.contains { $0["type"] == "transfers_empty" }, Comment(rawValue: run.output))
            let actions = records.filter { $0["type"] == "command_result" }.map { $0["action"] ?? "" }
            #expect(actions == ["get_preference", "set_preference", "unregister_account"], Comment(rawValue: run.output))
            #expect(records.contains { $0["action"] == "unregister_account" && $0["result"] == "cancelled" }, Comment(rawValue: run.output))
            let errors = records.filter { $0["type"] == "error" }.map { $0["message"] ?? "" }
            #expect(errors == [
                "Usage: /pref chatstates on|off", "Unknown preference: bogus. Available: chatstates, markers",
                "Unknown command: /bogus. Type 'help' for commands.", "Usage: send <jid> <message>", "Usage: /reply <jid> <message>",
                "No conversation target. Use: /sendfile [jid] <path>", "Usage: /senddirect <jid> <path>"
            ], Comment(rawValue: run.output))
            #expect(run.errors.contains("Connected. Type 'help' for commands, 'quit' to exit."), Comment(rawValue: run.errors))
            #expect(run.errors.contains("WARNING: This will permanently unregister your account from the server."), Comment(rawValue: run.errors))
            #expect(run.errors.contains("Type 'yes' to confirm:"), Comment(rawValue: run.errors))
        }
    }

    @Test
    func `a REPL reply reaches the reader while standard input stays open`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "json-repl-open") { _, profile in
            let run = try await profile.run(
                ["interactive", "--output", "json"], input: "/pref chatstates\n", until: "get_preference", atMarker: { _ in }, thenSignals: [SIGINT]
            )

            let results = try jsonRecords(run.output).filter { $0["type"] == "command_result" }
            #expect(results.map { $0["action"] } == ["get_preference"], Comment(rawValue: run.output))
            // The interrupt ended the run, so the record came from a CLI still running, not one flushing at exit.
            #expect(run.reason == .uncaughtSignal && run.exitCode == SIGINT, Comment(rawValue: run.errors))
        }
    }

    @Test
    func `an event record reaches the reader while the REPL waits for input`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "json-repl-idle") { _, profile in
            let run = try await profile.run(
                ["interactive", "--output", "json"], input: "", until: "\"type\":\"connected\"", atMarker: { _ in }, thenSignals: [SIGINT]
            )

            let records = try jsonRecords(run.output)
            #expect(records.contains { $0["type"] == "connected" }, Comment(rawValue: run.output))
            // The interrupt ended the run, so the record came from a CLI still running, not one flushing at exit.
            #expect(run.reason == .uncaughtSignal && run.exitCode == SIGINT, Comment(rawValue: run.errors))
        }
    }
}

/// Answers the server's service discovery with the blocking feature, so a block list command finds it supported.
private struct BlockingResponder: LoopbackIQResponder {
    func reply(to element: DuckoXMPP.XMLElement, id: String) -> String? {
        guard XMPPIQ(element: element).type == "get",
              element.child(named: "query", namespace: XMPPNamespaces.discoInfo) != nil,
              element.attribute("to").map({ $0 == "example.com" }) ?? true
        else { return nil }
        return "<iq type='result' id='\(id)' from='example.com'><query xmlns='\(XMPPNamespaces.discoInfo)'><feature var='\(XMPPNamespaces.blocking)'/></query></iq>"
    }
}
