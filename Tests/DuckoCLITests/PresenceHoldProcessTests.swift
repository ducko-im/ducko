import Darwin
import Testing

/// Runs the built CLI's `presence` hold against a loopback server.
@MainActor
struct PresenceHoldProcessTests {
    /// A closing terminal sends SIGHUP more than once, from the shell and again from the kernel, about 10 ms apart.
    @Test
    func `Closing the terminal during a hold disconnects cleanly and ends with the hang-up status`() async throws {
        let (run, sawStreamClose) = try await withLoopbackServer(responder: NoReplies(), profile: "presence-hold") { server, profile in
            let run = try await profile.run(
                ["presence", "away", "--for", "60s", "--output", "plain"], input: "", until: "alice@example.com is away",
                atMarker: { _ in }, thenSignals: [SIGHUP, SIGHUP]
            )
            return await (run, server.sawStreamClose)
        }

        #expect(run.reason == .exit && run.exitCode == 128 + SIGHUP, Comment(rawValue: run.output + run.errors))
        #expect(sawStreamClose, Comment(rawValue: run.errors))
        #expect(!run.errors.contains("Interrupted"), Comment(rawValue: run.errors))
    }
}
