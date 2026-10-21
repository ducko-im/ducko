import DuckoCore
import Foundation
import Testing
@testable import DuckoXMPP

@MainActor
struct SignInSecurityProcessTests {
    @Test
    func `An account that requires SCRAM refuses a PLAIN-only server and reports why in JSON`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "sign-in-refused") { server, profile in
            try await requireSCRAM(in: profile)

            let run = try await profile.run(["profile", "--output", "json"])

            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(run.exitCode != 0)
            let records = try run.output.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let refusal = records.first { $0["type"] as? String == "sign_in_refused" }
            #expect(refusal?["reason"] as? String == "plain_after_scram", Comment(rawValue: run.output + run.errors))
            #expect(await !(server.authenticated))
        }
    }

    @Test
    func `account reset-security lets the next sign-in send the password`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "sign-in-reset") { server, profile in
            try await requireSCRAM(in: profile)

            let reset = try await profile.run(["account", "reset-security", "alice@example.com"])
            #expect(reset.exitCode == 0, Comment(rawValue: reset.output + reset.errors))
            #expect(try await profile.makeStore().fetchAccounts().first?.requiresSCRAM == false)

            let run = try await profile.run(["profile", "--output", "json"])
            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(await server.authenticated, Comment(rawValue: run.output + run.errors))
        }
    }

    private func requireSCRAM(in profile: ThrowawayProfile) async throws {
        let store = try profile.makeStore()
        let account = try #require(try await store.fetchAccounts().first)
        try await store.setRequiresSCRAM(true, accountID: account.id)
    }
}

private struct NoReplies: LoopbackIQResponder {
    func reply(to _: DuckoXMPP.XMLElement, id _: String) -> String? {
        nil
    }
}
