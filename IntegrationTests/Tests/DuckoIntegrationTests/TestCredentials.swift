import Foundation

/// XMPP test account credentials sourced from environment variables.
///
/// On first access, falls back to parsing `IntegrationTests/.env.test` (adjacent
/// to this nested package's `Package.swift`) so callers do not need to `source`
/// the file before running `swift test --package-path IntegrationTests`. Existing
/// environment variables always win — sourcing in the shell still overrides.
///
/// Integration tests skip cleanly when these are unset (`isAvailable == false`),
/// so the test target builds and runs in CI without requiring secrets.
///
/// ## Test account preconditions
///
/// The specialized-protocol test suites assume baseline state on the operator-
/// managed accounts. Tests fail fast via `#require` when the baseline is
/// missing — they do not silently skip.
///
/// - **Mutual roster subscription between alice ↔ bob and alice ↔ carol.**
///   Required so PEP+ avatar-metadata notifications flow across accounts
///   (`AvatarTests`). Recommended for any future test that needs PEP fan-out.
/// - **Pre-published vCard on alice.** Required by `ProfileTests`: the suite
///   round-trips an existing profile because `ProfileService` has no delete
///   API, so a "synthesize then restore" path would leak vCard state
///   server-side. `AvatarTests` publishes and restores each account's avatar
///   within the test body, so no avatar baseline is required.
/// - **Dave has no baseline subscription with any other account.** Required by
///   `RosterTests` subscription/denial mutation tests so alice↔bob and
///   alice↔carol baselines are never mutated.
enum TestCredentials {
    struct Credential {
        let jid: String
        let password: String
        let label: String
    }

    static let mucService = "conference.xmpp.tobiha.de"

    /// Domain part the bootstrap-reset gate expects on every available
    /// credential before it touches PEP. A mismatch indicates the test
    /// credentials were aimed at the wrong server (production, staging,
    /// developer's personal account) — auto-reset bails rather than
    /// retracting devicelists on an unintended target.
    static let testServerDomain = "xmpp.tobiha.de"

    /// Baseline gate for the root integration suite — requires Alice, Bob, Carol.
    /// Dave is a newer addition; requiring him here would skip every existing
    /// integration test in environments that have only the three-account baseline.
    static var isAvailable: Bool {
        isSet("DUCKO_TEST_ALICE_JID")
            && isSet("DUCKO_TEST_ALICE_PASSWORD")
            && isSet("DUCKO_TEST_BOB_JID")
            && isSet("DUCKO_TEST_BOB_PASSWORD")
            && isSet("DUCKO_TEST_CAROL_JID")
            && isSet("DUCKO_TEST_CAROL_PASSWORD")
    }

    /// Narrower gate applied only to roster subscription/denial tests that
    /// depend on Dave's clean-roster baseline.
    static var isDaveAvailable: Bool {
        isSet("DUCKO_TEST_DAVE_JID")
            && isSet("DUCKO_TEST_DAVE_PASSWORD")
    }

    /// Opt-in gate for the destructive `account register`/`unregister`
    /// round-trip in `CLIAccountTests`. Off by default, mirroring the
    /// `DUCKO_RESET_FIXTURES` gate on `ResetTestServerState` — enable only
    /// against a server whose XEP-0077 in-band registration is known-good.
    static var isRegistrationTestingEnabled: Bool {
        env("DUCKO_TEST_REGISTRATION") == "1"
    }

    /// Opt-in gate for `SASLUpgradeTests`, which needs an account on a server that offers the XEP-0480 upgrade to
    /// SCRAM-SHA-256, and a command that makes it offer the upgrade again.
    static var isSASLUpgradeTestingEnabled: Bool {
        isSet("DUCKO_TEST_SASL_UPGRADE_JID")
            && isSet("DUCKO_TEST_SASL_UPGRADE_PASSWORD")
            && isSet("DUCKO_TEST_SASL_UPGRADE_RESET_COMMAND")
            && saslUpgradePort != nil
    }

    /// Opt-in gate for `CLISSOTests`, which signs Alice and Bob in through the test server's OAuth provider. It changes
    /// stored credentials only in throwaway profiles, but it adds grants at the provider and revokes one.
    static var isSSOTestingEnabled: Bool {
        env("DUCKO_TEST_SSO") == "1"
            && isSet("DUCKO_TEST_ALICE_JID") && isSet("DUCKO_TEST_ALICE_PASSWORD")
            && isSet("DUCKO_TEST_BOB_JID") && isSet("DUCKO_TEST_BOB_PASSWORD")
    }

    /// High-entropy ephemeral username for the destructive registration
    /// round-trip, e.g. `ducko-it-3f2a1b9c1d2e`. Randomized so concurrent runs
    /// against the shared server do not collide; the test using it surfaces a
    /// conflict rather than silently reusing an existing account.
    static func ephemeralUsername() -> String {
        "ducko-it-" + UUID().uuidString.prefix(12).lowercased()
    }

    static var alice: Credential {
        credential(jidVar: "DUCKO_TEST_ALICE_JID", passwordVar: "DUCKO_TEST_ALICE_PASSWORD", label: "alice")
    }

    static var bob: Credential {
        credential(jidVar: "DUCKO_TEST_BOB_JID", passwordVar: "DUCKO_TEST_BOB_PASSWORD", label: "bob")
    }

    static var carol: Credential {
        credential(jidVar: "DUCKO_TEST_CAROL_JID", passwordVar: "DUCKO_TEST_CAROL_PASSWORD", label: "carol")
    }

    static var dave: Credential {
        credential(jidVar: "DUCKO_TEST_DAVE_JID", passwordVar: "DUCKO_TEST_DAVE_PASSWORD", label: "dave")
    }

    static var saslUpgrade: Credential {
        credential(jidVar: "DUCKO_TEST_SASL_UPGRADE_JID", passwordVar: "DUCKO_TEST_SASL_UPGRADE_PASSWORD", label: "sasl-upgrade")
    }

    /// The client port of the `saslUpgrade` account's server.
    static var saslUpgradePort: UInt16? {
        env("DUCKO_TEST_SASL_UPGRADE_PORT").flatMap { UInt16($0) }
    }

    /// The shell command that removes the `saslUpgrade` account's SCRAM-SHA-256 credential, so its server offers
    /// the upgrade again.
    static var saslUpgradeResetCommand: String {
        env("DUCKO_TEST_SASL_UPGRADE_RESET_COMMAND") ?? ""
    }

    private static func credential(jidVar: String, passwordVar: String, label: String) -> Credential {
        Credential(jid: env(jidVar) ?? "", password: env(passwordVar) ?? "", label: label)
    }

    /// Whether `key` holds a non-empty value. A `.env.test` copied from the example leaves some keys empty, and their
    /// suites should skip rather than fail at sign-in.
    private static func isSet(_ key: String) -> Bool {
        !(env(key) ?? "").isEmpty
    }

    private static func env(_ key: String) -> String? {
        _ = loadEnvFileOnce
        return ProcessInfo.processInfo.environment[key]
    }

    private static let loadEnvFileOnce: Void = loadEnvFile()

    private static func loadEnvFile() {
        // TestCredentials.swift lives at:
        //   IntegrationTests/Tests/DuckoIntegrationTests/TestCredentials.swift
        // .env.test lives at:
        //   IntegrationTests/.env.test
        let envFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DuckoIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // IntegrationTests
            .appendingPathComponent(".env.test")

        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }

            let key = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2) ||
                (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }

            if ProcessInfo.processInfo.environment[key] == nil {
                setenv(key, value, 1)
            }
        }
    }
}
