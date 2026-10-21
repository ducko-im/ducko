import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIAvatarTests {
        @Test
        @MainActor func `avatar get fetches the own avatar or reports none`() async throws {
            try await CLIProcess.withProcess { cli in
                let alice = TestCredentials.alice
                try await cli.seedAccount(alice)

                let savePath = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ducko-inttest-avatar-\(UUID().uuidString).png").path
                await cli.addCleanup { try? FileManager.default.removeItem(atPath: savePath) }

                // No avatar baseline is guaranteed for alice (`TestCredentials`), so accept either the
                // saved-file path or the not-found message — both are clean exits.
                let output = try await cli.run(["avatar", "get", alice.jid, "--save", savePath])
                #expect(output.exitCode == 0)
                #expect(output.stdout.contains("Saved avatar to") || output.stdout.contains("No avatar found"))
            }
        }

        @Test(.timeLimit(.minutes(2)))
        @MainActor func `avatar set publishes an image that avatar get round-trips`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                let alice = try #require(harness.accounts["alice"])
                let aliceJID = try harness.jid(for: TestCredentials.alice)

                // Capture alice's current avatar in-process so cleanup restores the bytes that were
                // actually on the server, regardless of what the CLI publishes below.
                let originalAvatar = await harness.environment.avatarService.fetchAvatar(for: aliceJID, accountID: alice.accountID)

                // Restore runs at harness teardown — after the nested CLI work — and must reconnect
                // first because the capture step disconnects the in-process session. Registered after
                // `setUp`'s disconnect cleanup, so LIFO runs this restore before that disconnect.
                harness.addCleanup {
                    try? await harness.environment.accountService.connect(
                        accountID: alice.accountID, password: TestCredentials.alice.password
                    )
                    try? await alice.waitForCondition({
                        if case .connected = harness.environment.accountService.connectionStates[alice.accountID] { return true }
                        return false
                    }, timeout: TestTimeout.connect)
                    if let originalAvatar {
                        try? await harness.environment.avatarService.publishAvatar(
                            imageData: originalAvatar.data, accountID: alice.accountID
                        )
                    } else {
                        try? await harness.environment.avatarService.removeAvatar(accountID: alice.accountID)
                    }
                }

                // Free the in-process session so it never overlaps the CLI's alice session.
                await harness.environment.accountService.disconnect(accountID: alice.accountID)
                try await harness.waitUntilDisconnected("alice")

                try await CLIProcess.withProcess { cli in
                    try await cli.seedAccount(TestCredentials.alice)

                    let pngPath = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ducko-inttest-avatar-set-\(UUID().uuidString).png")
                    try AvatarFixtures.minimalPNG().write(to: pngPath)
                    await cli.addCleanup { try? FileManager.default.removeItem(at: pngPath) }

                    let set = try await cli.run(["avatar", "set", pngPath.path])
                    #expect(set.exitCode == 0)
                    #expect(set.stdout.contains("Avatar published successfully."))
                    let publishedHash = try #require(
                        set.stdout.split(separator: "\n").first { $0.hasPrefix("Hash: ") }?.dropFirst("Hash: ".count)
                    )
                    #expect(set.stdout.contains("Size:"))

                    let outPath = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ducko-inttest-avatar-get-\(UUID().uuidString).png")
                    await cli.addCleanup { try? FileManager.default.removeItem(at: outPath) }

                    let got = try await cli.run(["avatar", "get", TestCredentials.alice.jid, "--save", outPath.path])
                    #expect(got.exitCode == 0)
                    #expect(got.stdout.contains("Saved avatar to"))

                    // The saved bytes hashing to the hash `set` printed proves `get` read back exactly
                    // the PNG that `set` published.
                    let savedData = try Data(contentsOf: outPath)
                    #expect(sha1Hex(Array(savedData)) == String(publishedHash))
                }
            }
        }
    }
}
