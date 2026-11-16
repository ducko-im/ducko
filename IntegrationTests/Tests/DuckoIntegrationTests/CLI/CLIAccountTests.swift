import Foundation
import os
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIAccountTests {
        @Test
        @MainActor func `account list reports no accounts when none configured`() async throws {
            try await CLIProcess.withProcess { cli in
                let output = try await cli.run(["account", "list", "--output", "plain"])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account add stores a new account`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains(alice.jid))
            }
        }

        @Test
        @MainActor func `account add --no-connect persists the account offline`() async throws {
            try await CLIProcess.withProcess { cli in
                // A closed loopback endpoint is never reached: `seedUnreachableAccount`
                // runs `account add … --no-connect` and its clean-exit guard proves no
                // connect was attempted; the list assertion proves the account persisted.
                let port = try CLIProcess.reserveClosedLoopbackPort()
                try await cli.seedUnreachableAccount(
                    jid: "offline@example.com", host: "127.0.0.1", port: port
                )

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("offline@example.com"))
            }
        }

        @Test
        @MainActor func `account delete removes an account`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let deleted = try await cli.run(["account", "delete", alice.jid])
                #expect(deleted.exitCode == 0)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account delete matches a case-variant JID`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Lookups normalize through BareJID, so an upper-cased JID
                // resolves to the stored (case-folded) account.
                let deleted = try await cli.run(["account", "delete", alice.jid.uppercased()])
                #expect(deleted.exitCode == 0)

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains("No accounts configured."))
            }
        }

        @Test
        @MainActor func `account unregister matches a case-variant JID before confirming`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // Decline the confirmation so the account is only resolved (proving
                // the case-variant lookup matched) and never unregistered on the server.
                let output = try await cli.run(
                    ["account", "unregister", alice.jid.uppercased()],
                    stdin: "no\n"
                )
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Cancelled."))
            }
        }

        @Test(arguments: ["plain", "json", "ansi"])
        @MainActor func `account check-registration shows the form or errors cleanly`(format: String) async throws {
            try await CLIProcess.withProcess { cli in
                // Pre-auth form retrieval needs no seeded account.
                let output = try await cli.run([
                    "account", "check-registration",
                    "--server", TestCredentials.testServerDomain,
                    "--output", format
                ])

                // Load-bearing guard: the command must exit cleanly (no crash/hang). A bare
                // non-zero-exit disjunction would also pass on a TLS/connection/parser failure.
                #expect(output.terminationReason == .exit)

                // On any non-`result` response (including registration-disabled), the pre-auth
                // `fetchForm` throws the generic `unexpectedResponse`, which `CheckRegistration.run`
                // lets propagate to ArgumentParser → an "Error:" stderr prefix regardless of --output.
                let formAnchor = format == "json" ? "registration_form" : "Registration Form"
                let succeeded = output.exitCode == 0 && output.stdout.contains(formAnchor)
                let failedCleanly = output.exitCode != 0 && output.stderr.contains("Error:")
                #expect(succeeded || failedCleanly)
            }
        }

        @Test(.enabled(if: TestCredentials.isRegistrationTestingEnabled, "DUCKO_TEST_REGISTRATION not set"), .timeLimit(.minutes(2)))
        @MainActor func `account register then unregister round-trips an ephemeral account`() async throws {
            try await CLIProcess.withProcess { cli in
                let username = TestCredentials.ephemeralUsername()
                let password = UUID().uuidString
                let domain = TestCredentials.testServerDomain
                let jid = "\(username)@\(domain)"

                // `registerAccount` calls `createAndConnect`, persisting and connecting the account
                // in this profile's store (the connect publishes the ephemeral account's own OMEMO
                // devicelist — removed with the account on XEP-0077 cancel below).
                let registered = try await cli.run([
                    "account", "register",
                    "--server", domain,
                    "--username", username,
                    "--password", password
                ])
                #expect(registered.exitCode == 0)
                #expect(registered.stdout.contains("Account registered: \(jid)"))

                // Register failure-surfacing cleanup immediately, in a fresh process — the register
                // connection may be dead, and a body-unregister failure must still run orphan cleanup.
                let bodyUnregisterSucceeded = OSAllocatedUnfairLock(initialState: false)
                await cli.addCleanup {
                    guard let teardown = try? await cli.run(["account", "unregister", jid], stdin: "yes\n") else {
                        Issue.record("Ephemeral account \(jid) cleanup did not complete; it may be orphaned on the server")
                        return
                    }
                    let alreadyGone = teardown.stdout.contains("Account not found") || teardown.stderr.contains("Account not found")
                    // "Account not found" is clean only when the body already unregistered the account.
                    // Without that, it can also mean register succeeded server-side but rolled the local
                    // account back — a server orphan the CLI cannot cancel (it needs a local account).
                    let cleanlyGone = alreadyGone && bodyUnregisterSucceeded.withLock { $0 }
                    if teardown.exitCode != 0, !cleanlyGone {
                        Issue.record("Ephemeral account \(jid) was not cleanly unregistered (exit \(teardown.exitCode)); it may be orphaned on the server: \(teardown.stdout)\(teardown.stderr)")
                    }
                }

                // Exercise the explicit unregister; `cancelAccount` removes the local account, so the
                // cleanup above then hits the "Account not found" clean path.
                let unregistered = try await cli.run(["account", "unregister", jid], stdin: "yes\n")
                #expect(unregistered.exitCode == 0)
                #expect(unregistered.stdout.contains("Account unregistered: \(jid)"))
                if unregistered.exitCode == 0 {
                    bodyUnregisterSucceeded.withLock { $0 = true }
                }
            }
        }

        @Test
        @MainActor func `account delete reports an error for an invalid JID`() async throws {
            try await CLIProcess.withProcess { cli in
                // A bare JID cannot carry a resource, so this is rejected by
                // BareJID parsing before any account lookup.
                let output = try await cli.run(["account", "delete", "alice@example.com/resource"])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Invalid JID"))
            }
        }

        @Test
        @MainActor func `account add rejects a duplicate JID`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                // The duplicate guard rejects before any connection, so the
                // password is never consumed — a placeholder keeps the real
                // credential out of the child process argv.
                let duplicate = try await cli.run([
                    "account", "add", alice.jid, "--password", "unused"
                ])
                #expect(duplicate.exitCode != 0)
                #expect(duplicate.stderr.contains("already exists"))

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                let matches = listed.stdout
                    .split(separator: "\n")
                    .filter { $0.contains(alice.jid) }
                #expect(matches.count == 1)
            }
        }

        @Test
        @MainActor func `account delete reports an error for an unknown JID`() async throws {
            try await CLIProcess.withProcess { cli in
                // No `seedAccount` here — `accountService.accounts` is empty,
                // so `Account.Delete.run` throws `CLIError.accountNotFound(jid)`,
                // whose description reads "Account not found: <jid>".
                // ArgumentParser routes throws to stderr with a non-zero exit.
                let alice = TestCredentials.alice
                let output = try await cli.run(["account", "delete", alice.jid])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Account not found: \(alice.jid)"))
            }
        }

        @Test
        @MainActor func `account delete leaves an unrelated account untouched`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob
                try await cli.seedAccount(alice)

                let output = try await cli.run(["account", "delete", bob.jid])
                #expect(output.exitCode != 0)
                #expect(output.stderr.contains("Account not found: \(bob.jid)"))

                let listed = try await cli.run(["account", "list", "--output", "plain"])
                #expect(listed.exitCode == 0)
                #expect(listed.stdout.contains(alice.jid))
            }
        }
    }
}
