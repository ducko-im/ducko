import DuckoCore
import DuckoXMPP
import Foundation
import Testing

extension DuckoIntegrationTests.CLILayer {
    struct CLIRoomTests {
        @Test
        @MainActor func `REPL /join enters a MUC room`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let roomJID = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(roomJID)")

                // Register /destroy cleanup BEFORE the join confirmation wait
                // — if the join succeeded server-side but the wait misses, the
                // locked `inttest-*` room would otherwise linger on the live
                // server. Cleanup runs LIFO, so this fires before the REPL
                // terminate() registered above.
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/destroy")
                }

                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test
        @MainActor func `ducko room send delivers a group message via the CLI`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // Harness creates and unlocks the room
                // (`createEphemeralRoom` calls `acceptDefaultConfig` on a
                // newly-created room) so bob's REPL and alice's CLI
                // process can both join it.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                try await CLIProcess.withProcess { aliceCLI in
                    try await CLIProcess.withProcess { bobCLI in
                        let alice = TestCredentials.alice
                        let bob = TestCredentials.bob

                        try await aliceCLI.seedAccount(alice)

                        let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                        await bobCLI.addCleanup { await bobREPL.terminate() }

                        try await bobREPL.send("/join \(roomJID.description)")
                        _ = try await bobREPL.waitForOutput(
                            containing: "Joined ",
                            timeout: TestTimeout.event
                        )

                        // Drive the actual `DuckoCLI.Room.Send` surface:
                        // it joins → sends → leaves. Use a distinct
                        // nickname so this second alice session does not
                        // collide with the harness alice already in the
                        // room as "alice".
                        let body = "msg-\(UUID().uuidString.prefix(8))"
                        let sent = try await aliceCLI.run([
                            "room", "send", roomJID.description, body,
                            "--nickname", "alice-cli",
                            "--output", "plain"
                        ])
                        #expect(sent.exitCode == 0)

                        _ = try await bobREPL.waitForOutput(
                            containing: body,
                            timeout: TestTimeout.event
                        )
                    }
                }
            }
        }

        @Test
        @MainActor func `REPL prints a delivered group message and its join once`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // `createEphemeralRoom` calls `mucModule.acceptDefaultConfig`
                // on the newly-created room so non-owner joins succeed. This
                // hybrid setup covers the in-process group-send path; the
                // pure-CLI `/config submit-default` unlock is covered separately.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")
                let aliceAccount = try #require(harness.accounts["alice"])

                try await CLIProcess.withProcess { bobCLI in
                    let bob = TestCredentials.bob
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID.description)")
                    _ = try await bobREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )

                    // Drive alice's send through the in-process service:
                    // the regular-REPL `send <jid> <body>` form only
                    // routes to `sendGroupMessage` when that REPL's own
                    // `roomParticipants[jidString]` is non-empty, which
                    // requires the sending REPL to have `/join`'d. Alice
                    // has no REPL counterpart in this hybrid setup.
                    let body = "msg-\(UUID().uuidString.prefix(8))"
                    try await harness.environment.chatService.sendGroupMessage(
                        toJIDString: roomJID.description,
                        body: body,
                        accountID: aliceAccount.accountID
                    )

                    _ = try await bobREPL.waitForOutput(
                        containing: body,
                        timeout: TestTimeout.event
                    )

                    // Waiting for a later message gives any duplicate line of the first message time to print.
                    let laterBody = "msg-\(UUID().uuidString.prefix(8))"
                    try await harness.environment.chatService.sendGroupMessage(
                        toJIDString: roomJID.description,
                        body: laterBody,
                        accountID: aliceAccount.accountID
                    )
                    let output = try await bobREPL.waitForOutput(
                        containing: laterBody,
                        timeout: TestTimeout.event
                    )
                    #expect(output.ranges(of: body).count == 1)
                    #expect(output.ranges(of: "Joined ").count == 1)
                }
            }
        }

        @Test
        @MainActor func `REPL /leave exits the room`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let roomJID = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(roomJID)")

                // The test body sends `/leave` mid-flight, which clears the
                // REPL's `currentRoom` and renders a follow-up `/destroy`
                // a no-op. Cleanup re-joins so it can still destroy the
                // (locked) room rather than leaving it server-side. Wait on
                // the join confirmation rather than a fixed sleep so cleanup
                // succeeds against a slow server roundtrip without flaking on
                // a fast one.
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/join \(roomJID)")
                    _ = try? await aliceREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )
                    try? await aliceREPL.send("/destroy")
                }

                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )

                try await aliceREPL.send("/leave")
                _ = try await aliceREPL.waitForOutput(
                    containing: "Left ",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test
        @MainActor func `REPL /members lists occupants`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])

                // Same hybrid shape as the room-send test — alice creates the room
                // in-process (so `acceptDefaultConfig` runs), bob joins via REPL.
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                try await CLIProcess.withProcess { bobCLI in
                    let bob = TestCredentials.bob
                    let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                    await bobCLI.addCleanup { await bobREPL.terminate() }

                    try await bobREPL.send("/join \(roomJID.description)")
                    _ = try await bobREPL.waitForOutput(
                        containing: "Joined ",
                        timeout: TestTimeout.event
                    )

                    try await bobREPL.send("/members")
                    // Alice's nickname in the harness is the account's
                    // label, which is "alice" here.
                    _ = try await bobREPL.waitForOutput(
                        containing: "alice",
                        timeout: TestTimeout.event
                    )
                }
            }
        }

        @Test
        @MainActor func `REPL /config submit-default unlocks a freshly created room`() async throws {
            // Pure-CLI room unlock: alice creates a locked (status-201) room and opens it via the new
            // `/config submit-default` REPL surface — no in-process `TestHarness.createEphemeralRoom`
            // needed — then a second CLI process joins the now-unlocked room.
            try await CLIProcess.withProcessPair { aliceCLI, bobCLI in
                let alice = TestCredentials.alice
                let bob = TestCredentials.bob

                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let roomJID = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(roomJID)")
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/destroy")
                }
                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )
                // The freshly-created (status-201) room is locked, so /join prints the unlock hint.
                _ = try await aliceREPL.waitForOutput(
                    containing: "Room created and locked",
                    timeout: TestTimeout.event
                )

                try await aliceREPL.send("/config submit-default")
                _ = try await aliceREPL.waitForOutput(
                    containing: "Submitted default room configuration",
                    timeout: TestTimeout.event
                )

                // A second CLI can now join the unlocked room.
                let bobREPL = try await REPLSession.start(cli: bobCLI, credentials: bob)
                await bobCLI.addCleanup { await bobREPL.terminate() }
                try await bobREPL.send("/join \(roomJID)")
                _ = try await bobREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )
            }
        }

        @Test(.disabled("Pending two-process implementation."))
        @MainActor func `alice kicks bob from the room`() {
            // Mirror the two-process room-admin pattern used by the
            // adjacent enabled tests.
        }

        @Test
        @MainActor func `REPL send to unjoined room on a known MUC domain prints a hint`() async throws {
            // After joining one ephemeral room, the MUC-service domain is
            // recorded in `chatService.roomParticipants`. Sending a 1:1
            // `send` to a sibling JID on the same domain must trip the
            // unjoined-room heuristic and print the hint before falling
            // through to a regular bare-JID send. Asserting the hint
            // pins the new branch in `handleSendCommand`.
            try await CLIProcess.withProcess { aliceCLI in
                let alice = TestCredentials.alice
                let aliceREPL = try await REPLSession.start(cli: aliceCLI, credentials: alice)
                await aliceCLI.addCleanup { await aliceREPL.terminate() }

                let joinedRoom = Self.makeEphemeralRoomJID()
                try await aliceREPL.send("/join \(joinedRoom)")
                await aliceCLI.addCleanup {
                    try? await aliceREPL.send("/destroy")
                }
                _ = try await aliceREPL.waitForOutput(
                    containing: "Joined ",
                    timeout: TestTimeout.event
                )

                let unjoinedRoom = "inttest-\(UUID().uuidString.prefix(8).lowercased())@\(TestCredentials.mucService)"
                try await aliceREPL.send("send \(unjoinedRoom) hello")
                // Hint string is unique to this branch, so a buffer-wide
                // match cannot collide with output from earlier commands.
                _ = try await aliceREPL.waitForOutput(
                    containing: "Hint: send <room-jid> requires /join first",
                    timeout: TestTimeout.replOutput
                )
            }
        }

        @Test
        @MainActor func `JSON REPL lists a room's affiliations as records and prints the unlock hint on standard error`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                try await aliceCLI.seedAccount(TestCredentials.alice)
                let roomJID = Self.makeEphemeralRoomJID()

                let output = try await aliceCLI.run(
                    ["interactive", "--output", "json"], stdin: "/join \(roomJID)\n/affiliations owner\n/destroy\n"
                )

                let records = try output.jsonRecords()
                let groupIndex = try #require(records.firstIndex { $0["type"] == "affiliation_group" }, Comment(rawValue: output.stdout))
                #expect(records[groupIndex]["affiliation"] == "owner")
                // Event records print from background tasks, so one can land between the entries. A loop rather than a
                // `prefix` or `filter` closure: here the compiler returned an empty `prefix` and crashed on `filter`.
                var affiliations: [String?] = []
                for record in records[(groupIndex + 1)...] where record["type"] == "affiliation" {
                    affiliations.append(record["affiliation"])
                }
                #expect(!affiliations.isEmpty, Comment(rawValue: output.stdout))
                #expect(Set(affiliations) == ["owner"], Comment(rawValue: output.stdout))
                #expect(output.stderr.contains("Room created and locked — "), Comment(rawValue: output.stderr))
            }
        }

        @Test
        @MainActor func `room join prints its guidance on standard error and only records on standard output`() async throws {
            try await TestHarness.withHarness { harness in
                try await harness.setUp(accounts: ["alice": TestCredentials.alice])
                let roomJID = try await harness.createEphemeralRoom(using: "alice")

                try await CLIProcess.withProcess { aliceCLI in
                    try await aliceCLI.seedAccount(TestCredentials.alice)

                    let output = try await aliceCLI.run(
                        ["room", "join", roomJID.description, "--nickname", "alice-cli", "--output", "json"], stdin: "bogus\nquit\n"
                    )

                    let records = try output.jsonRecords()
                    #expect(records.contains { $0["type"] == "room_joined" }, Comment(rawValue: output.stdout))
                    #expect(output.stderr.contains("Type 'send <message>' to send, 'quit' to leave."), Comment(rawValue: output.stderr))
                    #expect(output.stderr.contains("Commands: send <message>, quit"), Comment(rawValue: output.stderr))
                }
            }
        }

        @Test
        @MainActor func `JSON REPL prints the unjoined-room hint on standard error`() async throws {
            try await CLIProcess.withProcess { aliceCLI in
                try await aliceCLI.seedAccount(TestCredentials.alice)
                let joinedRoom = Self.makeEphemeralRoomJID()
                let unjoinedRoom = Self.makeEphemeralRoomJID()

                let output = try await aliceCLI.run(
                    ["interactive", "--output", "json"], stdin: "/join \(joinedRoom)\nsend \(unjoinedRoom) hi\n/destroy\n"
                )

                let records = try output.jsonRecords()
                #expect(records.contains { $0["type"] == "room_joined" }, Comment(rawValue: output.stdout))
                #expect(output.stderr.contains("Hint: send <room-jid> requires /join first; delivering as 1:1 message."), Comment(rawValue: output.stderr))
            }
        }

        // MARK: - Helpers

        private static func makeEphemeralRoomJID() -> String {
            // Lowercase so the JID matches what the server normalizes
            // localparts to (XMPP nodeprep). The CLI REPL's
            // `waitForRoomJoined` looks up
            // `chatService.roomParticipants[roomJID]` by raw string —
            // passing an uppercase UUID prefix wedges that helper for
            // its full 15 s timeout, which races the test's `/leave`
            // wait.
            "inttest-\(UUID().uuidString.prefix(8).lowercased())@\(TestCredentials.mucService)"
        }
    }
}
