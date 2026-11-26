import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    /// Sign-in through the browser against the test server's own OAuth provider. The test plays the browser: it reads
    /// the sign-in page the CLI prints, submits the provider's login and consent forms, and delivers the redirect to the
    /// CLI's loopback port.
    @Suite(.serialized, .enabled(if: TestCredentials.isSSOTestingEnabled, "DUCKO_TEST_SSO not set"))
    struct CLISSOTests {
        @Test(.timeLimit(.minutes(2)))
        func `account add --sso stores a grant and no password`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let added = try await signInThroughBrowser(cli, ["account", "add", alice.jid, "--sso", "--no-browser"], as: alice)
                #expect(added.exitCode == 0, Comment(rawValue: added.stderr))

                let listed = try await cli.run(["account", "list", "--output", "json"])
                let record = try #require(listed.jsonRecords().first { $0["jid"] == alice.jid })
                #expect(record["sign_in_method"] == "browser")
                let entries = try credentialEntries(cli)
                #expect(entries["secret:sso-grant:\(alice.jid)"] != nil)
                #expect(entries[alice.jid] == nil)
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func `a stored grant reconnects without the browser`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await requireSuccess(signInThroughBrowser(cli, ["account", "add", alice.jid, "--sso", "--no-browser"], as: alice))

                let roster = try await cli.run(["roster", "list"])
                #expect(roster.exitCode == 0, Comment(rawValue: roster.stderr))
                #expect(!roster.stderr.contains("Open this page to sign in"))
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func `an expired access token is refreshed on connect`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await requireSuccess(signInThroughBrowser(cli, ["account", "add", alice.jid, "--sso", "--no-browser"], as: alice))
                var grant = try grantJSON(cli, jid: alice.jid)
                let refreshTokenBefore = try #require(grant["refresh_token"] as? String)
                grant["expires_at"] = Date().addingTimeInterval(-60).timeIntervalSince1970
                try writeGrantJSON(grant, cli, jid: alice.jid)

                let roster = try await cli.run(["roster", "list"])
                #expect(roster.exitCode == 0, Comment(rawValue: roster.stderr))
                #expect(try grantJSON(cli, jid: alice.jid)["refresh_token"] as? String != refreshTokenBefore)
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func `a provider login as another account fails and keeps nothing`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob
                let added = try await signInThroughBrowser(cli, ["account", "add", alice.jid, "--sso", "--no-browser"], as: bob)
                #expect(added.exitCode != 0)
                #expect(added.stderr.contains(bob.jid), Comment(rawValue: added.stderr))

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(!listed.stdout.contains(alice.jid))
                #expect(try credentialEntries(cli)["secret:sso-grant:\(alice.jid)"] == nil)
            }
        }

        @Test(.timeLimit(.minutes(2)))
        func `deleting an account revokes its refresh token`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await requireSuccess(signInThroughBrowser(cli, ["account", "add", alice.jid, "--sso", "--no-browser"], as: alice))
                var grant = try grantJSON(cli, jid: alice.jid)
                let tokenEndpoint = try #require((grant["token_endpoint"] as? String).flatMap(URL.init(string:)))
                let clientID = try #require(grant["client_id"] as? String)
                let current = try #require(grant["refresh_token"] as? String)

                // The token still refreshes, so the later refusal comes from the revocation.
                let control = try await refresh(current, clientID: clientID, at: tokenEndpoint)
                #expect(control.status == 200)
                let rotated = try #require(control.json["refresh_token"] as? String)
                grant["refresh_token"] = rotated
                try writeGrantJSON(grant, cli, jid: alice.jid)

                let deleted = try await cli.run(["account", "delete", alice.jid])
                #expect(deleted.exitCode == 0, Comment(rawValue: deleted.stderr))

                let afterDelete = try await refresh(rotated, clientID: clientID, at: tokenEndpoint)
                #expect(afterDelete.status == 400)
                #expect(afterDelete.json["error"] as? String == "invalid_grant")
            }
        }

        @Test(.timeLimit(.minutes(3)))
        func `a password account switches to browser sign-in and signs in again`() async throws {
            try await CLIProcess.withProcess { cli in
                let bob = TestCredentials.bob
                let seeded = try await cli.run(["account", "add", bob.jid, "--password", bob.password, "--no-connect"])
                #expect(seeded.exitCode == 0, Comment(rawValue: seeded.stderr))

                let switched = try await signInThroughBrowser(
                    cli, ["account", "browser-sign-in", bob.jid, "--replace-password", "--no-browser"], as: bob
                )
                #expect(switched.exitCode == 0, Comment(rawValue: switched.stderr))
                let listed = try await cli.run(["account", "list", "--output", "json"])
                #expect(try listed.jsonRecords().first { $0["jid"] == bob.jid }?["sign_in_method"] == "browser")
                let entries = try credentialEntries(cli)
                #expect(entries["secret:sso-grant:\(bob.jid)"] != nil)
                #expect(entries[bob.jid] == nil)

                let refreshTokenBefore = try grantJSON(cli, jid: bob.jid)["refresh_token"] as? String
                let again = try await signInThroughBrowser(cli, ["account", "browser-sign-in", bob.jid, "--no-browser"], as: bob)
                #expect(again.exitCode == 0, Comment(rawValue: again.stderr))
                #expect(try grantJSON(cli, jid: bob.jid)["refresh_token"] as? String != refreshTokenBefore)
            }
        }
    }
}

// MARK: - Scripted browser

private let signInLinePrefix = "Open this page to sign in: "

/// Spawns `arguments`, completes the provider login it prints as `credential`, and returns the command's output.
private func signInThroughBrowser(_ cli: CLIProcess, _ arguments: [String], as credential: TestCredentials.Credential) async throws -> CLIOutput {
    let handle = try await cli.spawn(arguments)
    let stderr = try await handle.waitForStderr(containing: signInLinePrefix)
    let line = try #require(stderr.split(separator: "\n").first { $0.hasPrefix(signInLinePrefix) })
    let authorizationURL = try #require(URL(string: String(line.dropFirst(signInLinePrefix.count))))
    try await ProviderLogin().complete(authorizationURL, as: credential)
    return try await handle.awaitExit()
}

private func requireSuccess(_ output: CLIOutput) throws {
    guard output.exitCode == 0 else {
        throw TestHarnessError.nonZeroExit(code: output.exitCode, reason: output.terminationReason, stdout: output.stdout, stderr: output.stderr)
    }
}

/// Plays the browser through the test server's login and consent forms, without following redirects.
private struct ProviderLogin {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = HTTPCookieStorage()
        self.session = URLSession(configuration: configuration)
    }

    func complete(_ authorizationURL: URL, as credential: TestCredentials.Credential) async throws {
        // Checked before any credential is sent.
        try #require(authorizationURL.scheme == "https")
        try #require(authorizationURL.host() == TestCredentials.testServerDomain)
        try #require(authorizationURL.path() == "/oauth2/authorize")
        // This attempt's redirect URI: the CLI's loopback listener, on the issuer's callback path.
        let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let redirectURI = try #require(query.first { $0.name == "redirect_uri" }?.value)
        let redirect = try #require(URLComponents(string: redirectURI))
        try #require(redirect.scheme == "http" && redirect.host == "127.0.0.1" && redirect.port != nil)
        try #require(redirect.percentEncodedPath.wholeMatch(of: /\/oauth\/callback\/[0-9a-f]{16}/) != nil)
        try #require(redirect.percentEncodedQuery == nil && redirect.fragment == nil)
        let state = try #require(query.first { $0.name == "state" }?.value)

        _ = try await send(URLRequest(url: authorizationURL), expecting: 200)
        let localpart = String(credential.jid.prefix { $0 != "@" })
        let consentPage = try await send(formPost(authorizationURL, [("username", localpart), ("password", credential.password)]), expecting: 200)
        let inputs = Self.inputs(in: String(decoding: consentPage.data, as: UTF8.self))
        let userToken = try #require(inputs.first { $0["name"] == "user_token" }?["value"])
        let scopes = inputs.filter { $0["name"] == "scope" }.compactMap { $0["value"] }
        let consent = try await send(
            formPost(authorizationURL, [("user_token", userToken)] + scopes.map { ("scope", $0) } + [("consent", "granted")]),
            expecting: 303
        )
        // Followed only when it is this attempt's redirect URI, with the attempt's state.
        let location = try #require(consent.response.value(forHTTPHeaderField: "Location").flatMap { URLComponents(string: $0) })
        var target = location
        target.percentEncodedQuery = nil
        target.fragment = nil
        try #require(target.string == redirectURI)
        try #require(location.queryItems?.first { $0.name == "state" }?.value == state)
        _ = try await send(URLRequest(url: #require(location.url)), expecting: 200)
    }

    private func send(_ request: URLRequest, expecting status: Int) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == status, Comment(rawValue: String(decoding: data.prefix(500), as: UTF8.self)))
        return (data, http)
    }

    private func formPost(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(formEncoded(fields).utf8)
        return request
    }

    private static func inputs(in html: String) -> [[String: String]] {
        html.matches(of: /<input\b[^>]*>/).map { tag in
            Dictionary(tag.output.matches(of: /([a-zA-Z_-]+)="([^"]*)"/).map { (String($0.output.1), String($0.output.2)) }) { first, _ in first }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest) async -> URLRequest? {
        nil
    }
}

private func formEncoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0) ... Unicode.Scalar(127)))
    allowed.insert(charactersIn: "-._~")
    return fields.map { "\($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
        .joined(separator: "&")
}

/// Refreshes `refreshToken` at the provider directly, as Ducko's token client does.
private func refresh(_ refreshToken: String, clientID: String, at tokenEndpoint: URL) async throws -> (status: Int, json: [String: Any]) {
    var request = URLRequest(url: tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(formEncoded([("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", clientID)]).utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    return try (#require(response as? HTTPURLResponse).statusCode, json)
}

// MARK: - Profile credentials file

private func credentialsURL(_ cli: CLIProcess) -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Ducko-Dev-\(cli.profile)", isDirectory: true)
        .appendingPathComponent("credentials.json")
}

private func credentialEntries(_ cli: CLIProcess) throws -> [String: String] {
    try JSONDecoder().decode([String: String].self, from: Data(contentsOf: credentialsURL(cli)))
}

private func grantJSON(_ cli: CLIProcess, jid: String) throws -> [String: Any] {
    let encoded = try #require(credentialEntries(cli)["secret:sso-grant:\(jid)"])
    let data = try #require(Data(base64Encoded: encoded))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func writeGrantJSON(_ grant: [String: Any], _ cli: CLIProcess, jid: String) throws {
    var entries = try credentialEntries(cli)
    entries["secret:sso-grant:\(jid)"] = try JSONSerialization.data(withJSONObject: grant).base64EncodedString()
    try JSONEncoder().encode(entries).write(to: credentialsURL(cli), options: .atomic)
}
