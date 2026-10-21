import Foundation
import Testing
@testable import DuckoXMPP

@MainActor
struct RosterProcessTests {
    @Test(arguments: ["add", "remove", "interactive"])
    func `real CLI reports confirmed partial result and tears down`(operation: String) async throws {
        try await withLoopbackServer(responder: RosterResponder(), profile: "roster-local") { server, profile in
            let interactive = operation == "interactive"
            let run = try await profile.run(
                interactive ? ["interactive", "--output", "plain"] : ["roster", operation, "bob@example.com", "--output", "json"],
                input: interactive ? "/add bob@example.com\nhelp\nquit\n" : ""
            )
            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(await server.sawStreamClose)
            try assertOutput(operation: operation, text: run.output, errorText: run.errors, exitCode: run.exitCode)
        }
    }

    private func assertOutput(operation: String, text: String, errorText: String, exitCode: Int32) throws {
        if operation == "interactive" {
            #expect(exitCode == 0, Comment(rawValue: text + errorText))
            #expect(text.contains("sync"), Comment(rawValue: text))
            #expect(text.contains("Commands:"), Comment(rawValue: text))
        } else {
            #expect(exitCode == 3, Comment(rawValue: text + errorText))
            let objects = try text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let outcomes = objects.filter { $0["type"] as? String == "roster_command" }
            #expect(outcomes.count == 1)
            #expect(outcomes.first?["operation"] as? String == operation)
            #expect(outcomes.first?["remote_status"] as? String == "confirmed")
            #expect(outcomes.first?["local_status"] as? String == "incomplete")
            #expect(outcomes.first?["result"] as? String == "partial")
            #expect(!errorText.contains("Error:"))
        }
    }
}

/// Answers roster requests with an empty roster until a roster set comes in, and from then on with no roster at all,
/// so the CLI's readback after the change stays incomplete.
private struct RosterResponder: LoopbackIQResponder {
    private var mutated = false

    mutating func reply(to element: DuckoXMPP.XMLElement, id: String) -> String? {
        guard element.child(named: "query", namespace: XMPPNamespaces.roster) != nil else { return nil }
        if XMPPIQ(element: element).type == "set" { mutated = true }
        let body = mutated ? "" : "<query xmlns='jabber:iq:roster' ver='initial'/>"
        return "<iq type='result' id='\(id)'>\(body)</iq>"
    }
}
