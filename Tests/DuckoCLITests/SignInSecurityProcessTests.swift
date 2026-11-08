import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI
@testable import DuckoXMPP

@MainActor
struct SignInSecurityProcessTests {
    private let hint = plainRefusalHint(.storedAccount, jid: "alice@example.com")

    @Test
    func `An account that does not allow PLAIN refuses a PLAIN-only server and reports why in JSON`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "sign-in-refused") { server, profile in
            try await forbidPLAIN(in: profile)

            let run = try await profile.run(["profile", "--output", "json"])

            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(run.exitCode != 0)
            let records = try run.output.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let refusal = records.first { $0["type"] as? String == "sign_in_refused" }
            #expect(refusal?["reason"] as? String == "plain_not_allowed", Comment(rawValue: run.output + run.errors))
            #expect(run.errors.contains(hint), Comment(rawValue: run.errors))
            #expect(await !(server.authenticated))
        }
    }

    @Test
    func `A refused sign-in prints the refusal and names the command that allows PLAIN on standard error`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "sign-in-refused-plain") { _, profile in
            try await forbidPLAIN(in: profile)

            let run = try await profile.run(["profile", "--output", "plain"])

            #expect(run.output.split(separator: "\n").contains { $0 == plainSignInRefusedLine }, Comment(rawValue: run.output))
            #expect(!run.output.contains("account set"))
            #expect(run.errors.contains(hint), Comment(rawValue: run.errors))
        }
    }

    @Test
    func `account set changes only the settings it names, without connecting, and the next sign-in uses them`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "account-set") { server, profile in
            let store = try profile.makeStore()
            var account = try #require(try await store.fetchAccounts().first)
            account.requireTLS = true
            try await store.saveAccount(account)
            try await store.setAllowsPLAIN(false, accountID: account.id)

            let allow = try await profile.run(["account", "set", "alice@example.com", "--allow-plain"])
            #expect(allow.exitCode == 0, Comment(rawValue: allow.output + allow.errors))
            #expect(await !(server.authenticated))
            let afterAllow = try await accountRecord(in: profile)
            #expect(afterAllow["allowsPLAIN"] as? String == "true")
            #expect(afterAllow["requireTLS"] as? String == "true")

            let optional = try await profile.run(["account", "set", "alice@example.com", "--no-require-tls"])
            #expect(optional.exitCode == 0, Comment(rawValue: optional.output + optional.errors))
            let afterOptional = try await accountRecord(in: profile)
            #expect(afterOptional["allowsPLAIN"] as? String == "true")
            #expect(afterOptional["requireTLS"] as? String == "false")

            let run = try await profile.run(["profile", "--output", "json"])
            #expect(run.reason == .exit, Comment(rawValue: run.errors))
            #expect(await server.authenticated, Comment(rawValue: run.output + run.errors))
        }
    }

    @Test
    func `account add --allow-plain stores the permission`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "account-add-allow-plain") { _, profile in
            let add = try await profile.run(["account", "add", "bob@example.com", "--password", "secret", "--no-connect", "--allow-plain"])
            #expect(add.exitCode == 0, Comment(rawValue: add.output + add.errors))

            let list = try await profile.run(["account", "list", "--output", "json"])
            let records = try list.output.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let added = records.first { $0["jid"] as? String == "bob@example.com" }
            #expect(added?["allowsPLAIN"] as? String == "true", Comment(rawValue: list.output))
        }
    }

    /// The profile's only account as `account list --output json` prints it.
    private func accountRecord(in profile: ThrowawayProfile) async throws -> [String: Any] {
        let list = try await profile.run(["account", "list", "--output", "json"])
        return try #require(JSONSerialization.jsonObject(with: Data(list.output.utf8)) as? [String: Any], Comment(rawValue: list.output))
    }

    private func forbidPLAIN(in profile: ThrowawayProfile) async throws {
        let store = try profile.makeStore()
        let account = try #require(try await store.fetchAccounts().first)
        try await store.setAllowsPLAIN(false, accountID: account.id)
    }
}

private struct NoReplies: LoopbackIQResponder {
    func reply(to _: DuckoXMPP.XMLElement, id _: String) -> String? {
        nil
    }
}
