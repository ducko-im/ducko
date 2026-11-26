import DuckoCore
import DuckoData
import Foundation
import Testing
@testable import DuckoCLI

/// The CLI's commands for an account that signs in through the browser. A stored browser account here has no grant, so
/// its sign-in fails before the server is reached, the way a grant the provider no longer accepts does.
@MainActor
struct BrowserSignInProcessTests {
    private let signInAgain = browserSignInAgainHint(jid: "alice@example.com")
    private let noPassword = CLIError.noPassword.localizedDescription

    @Test
    func `A browser account without a grant names browser-sign-in, and is never asked for a password`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-no-grant") { server, profile in
            try await profile.makeBrowserAccount()

            let run = try await profile.run(["profile", "--output", "plain"])

            #expect(run.reason == .exit && run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            #expect(run.errors.contains(signInAgain), Comment(rawValue: run.errors))
            #expect(!run.errors.contains(noPassword), Comment(rawValue: run.errors))
            #expect(await !(server.authenticated))
        }
    }

    @Test
    func `An interactive session for a browser account without a grant names browser-sign-in once`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-no-grant-repl") { _, profile in
            try await profile.makeBrowserAccount()

            let run = try await profile.run(["interactive"], input: "quit\n")

            #expect(run.reason == .exit && run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            #expect(run.errors.components(separatedBy: signInAgain).count - 1 == 1, Comment(rawValue: run.errors))
        }
    }

    @Test
    func `account unregister connects a browser account without a password`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-unregister") { server, profile in
            try await profile.makeBrowserAccount()

            let run = try await profile.run(["account", "unregister", "alice@example.com"], input: "yes\n")

            #expect(run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            #expect(!run.output.contains("Account unregistered"), Comment(rawValue: run.output))
            #expect(run.errors.contains(signInAgain), Comment(rawValue: run.errors))
            #expect(!run.errors.contains(noPassword), Comment(rawValue: run.errors))
            #expect(await !(server.authenticated))
        }
    }

    /// Without a terminal no hidden line can be read, so the run ends at the first password it would ask for.
    @Test(arguments: [SignInMethod.password, .browser])
    func `account change-password asks a browser account only for the new password`(method: SignInMethod) async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-change-password") { _, profile in
            try await profile.forgetPassword()
            if method == .browser { try await profile.makeBrowserAccount() }

            let run = try await profile.run(["account", "change-password", "alice@example.com"])

            #expect(run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            let expected = switch method {
            case .password: noPassword
            case .browser: CLIError.noHiddenInput(field: "new password").localizedDescription
            }
            #expect(run.errors.contains(expected), Comment(rawValue: run.errors))
        }
    }

    @Test
    func `A password sign-in to a server that offers only browser sign-in names the switch to it`() async throws {
        try await withLoopbackServer(responder: NoReplies(), mechanisms: ["OAUTHBEARER"], profile: "browser-only-server") { server, profile in
            let run = try await profile.run(["profile", "--output", "json"])

            #expect(run.reason == .exit && run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            let records = try run.output.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
            let failure = records.first { $0["type"] as? String == "authentication_failed" }
            #expect(failure?["kind"] as? String == "browser_sign_in_only", Comment(rawValue: run.output + run.errors))
            #expect(run.errors.contains(browserSignInHint(.storedAccount, jid: "alice@example.com")), Comment(rawValue: run.errors))
            #expect(!run.errors.contains(signInAgain), Comment(rawValue: run.errors))
            #expect(await !(server.authenticated))
        }
    }

    @Test
    func `account list names each account's sign-in method`() async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-list") { _, profile in
            let before = try await profile.run(["account", "list", "--output", "json"])
            let passwordRecord = try #require(JSONSerialization.jsonObject(with: Data(before.output.utf8)) as? [String: Any], Comment(rawValue: before.output))
            #expect(passwordRecord["sign_in_method"] as? String == "password")

            try await profile.makeBrowserAccount()

            let json = try await profile.run(["account", "list", "--output", "json"])
            let browserRecord = try #require(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any], Comment(rawValue: json.output))
            #expect(browserRecord["sign_in_method"] as? String == "browser")
            let plain = try await profile.run(["account", "list", "--output", "plain"])
            #expect(plain.output.hasSuffix("Sign-in: browser, TLS: optional\n"), Comment(rawValue: plain.output))
        }
    }

    @Test(arguments: [false, true])
    func `account browser-sign-in names the other invocation when the account signs in the other way`(replacePassword: Bool) async throws {
        try await withLoopbackServer(responder: NoReplies(), profile: "browser-sign-in-mismatch") { server, profile in
            // --replace-password switches a password account, so a browser account refuses it. A password account
            // refuses the plain invocation.
            if replacePassword { try await profile.makeBrowserAccount() }

            let run = try await profile.run(
                ["account", "browser-sign-in", "alice@example.com", "--no-browser"] + (replacePassword ? ["--replace-password"] : [])
            )

            #expect(run.exitCode != 0, Comment(rawValue: run.output + run.errors))
            let hint = replacePassword ? signInAgain : browserSignInHint(.storedAccount, jid: "alice@example.com")
            #expect(run.errors.contains(hint), Comment(rawValue: run.errors))
            #expect(!run.errors.contains("Open this page to sign in"), Comment(rawValue: run.errors))
            #expect(await !(server.authenticated))
        }
    }
}

extension ThrowawayProfile {
    /// Makes the profile's account sign in through the browser, with neither a grant nor a password stored for it.
    func makeBrowserAccount() async throws {
        let store = try makeStore()
        let account = try #require(try await store.fetchAccounts().first)
        try await store.setSignInMethod(.browser, accountID: account.id)
        try await forgetPassword()
    }

    func forgetPassword() async throws {
        let account = try #require(try await makeStore().fetchAccounts().first)
        FileCredentialStore(fileURL: directory.appending(path: "credentials.json")).deletePassword(for: account.jid.description)
    }
}
