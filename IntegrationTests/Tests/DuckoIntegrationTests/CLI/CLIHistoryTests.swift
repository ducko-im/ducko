import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIHistoryTests {
        @Test
        @MainActor func `ducko history reports empty state on a fresh profile`() async throws {
            try await CLIProcess.withProcess { cli in
                // The standalone `History` subcommand has its own argument
                // parsing and process lifecycle distinct from the REPL
                // `/history` handler (covered by `CLIREPLTests`). Seeding
                // the account signs in, which catches up on the newest archive
                // page, so the test asks for an address no account has written
                // to. `printHistory` then emits "No messages found." and the
                // process exits 0 without contacting the server (`--server` not
                // passed).
                let alice = TestCredentials.alice
                let stranger = "inttest-\(UUID().uuidString.prefix(8).lowercased())@\(TestCredentials.testServerDomain)"
                try await cli.seedAccount(alice)

                let output = try await cli.run([
                    "history", stranger, "--output", "plain"
                ])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("No messages found."))
            }
        }
    }
}
