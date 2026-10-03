import Darwin
import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// The `acceptFailed` reason `accept` gives within a second, or `nil` when it does not fail with `acceptFailed`.
private func acceptFailureReason(_ listener: SOCKS5Listener) async -> String? {
    do {
        _ = try await listener.accept(expectedDstAddr: "dummy", timeout: 1)
        return nil
    } catch let SOCKS5Listener.ListenerError.acceptFailed(reason) {
        return reason
    } catch {
        return nil
    }
}

enum SOCKS5ListenerTests {
    struct StartListening {
        @Test
        func `Listener starts on ephemeral port`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()
            #expect(port > 0)
            await listener.close()
        }

        @Test
        func `Listener rejects double start`() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()
            await #expect(throws: SOCKS5Listener.ListenerError.self) {
                try await listener.start()
            }
            await listener.close()
        }
    }

    struct Handshake {
        @Test
        func `Server handshake with correct DST.ADDR succeeds`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let dstAddr = SOCKS5Connection.destinationAddress(
                sid: "test-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )

            // Spawn listener accept task
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: dstAddr, timeout: 5)
            }

            // Connect with a SOCKS5Connection client
            let client = SOCKS5Connection()
            try await client.connect(
                host: "127.0.0.1",
                port: port,
                destinationAddress: dstAddr
            )

            // Listener should return a valid connection
            let serverConn = try await acceptTask.value

            // Clean up
            await client.close()
            await serverConn.close()
            await listener.close()
            #expect(await acceptFailureReason(listener) == "Not listening")
        }

        @Test
        func `Server handshake with wrong DST.ADDR fails`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let correctAddr = SOCKS5Connection.destinationAddress(
                sid: "test-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )
            let wrongAddr = SOCKS5Connection.destinationAddress(
                sid: "wrong-sid",
                initiatorJID: "alice@example.com/res",
                targetJID: "bob@example.com/res"
            )

            // Spawn listener accept with the correct address expectation
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: correctAddr, timeout: 5)
            }

            // Client connects with wrong address — the client handshake will
            // fail because the server will reject the DST.ADDR and close the socket
            let client = SOCKS5Connection()
            do {
                try await client.connect(
                    host: "127.0.0.1",
                    port: port,
                    destinationAddress: wrongAddr
                )
            } catch {
                // Expected — server closed the connection
            }

            // Listener accept should fail
            await #expect(throws: Error.self) {
                try await acceptTask.value
            }

            await client.close()
            await listener.close()
        }
    }

    struct DataTransfer {
        @Test
        func `Data round-trip through listener-accepted connection`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let dstAddr = SOCKS5Connection.destinationAddress(
                sid: "round-trip-sid",
                initiatorJID: "sender@example.com/a",
                targetJID: "receiver@example.com/b"
            )

            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: dstAddr, timeout: 5)
            }

            let client = SOCKS5Connection()
            try await client.connect(
                host: "127.0.0.1",
                port: port,
                destinationAddress: dstAddr
            )

            let serverConn = try await acceptTask.value

            // Client sends data, server receives
            let testData: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F] // "Hello"
            try await client.send(testData)
            let received = try await serverConn.receive(testData.count)
            #expect(received == testData)

            // Server sends data back, client receives
            let replyData: [UInt8] = [0x57, 0x6F, 0x72, 0x6C, 0x64] // "World"
            try await serverConn.send(replyData)
            let reply = try await client.receive(replyData.count)
            #expect(reply == replyData)

            await client.close()
            await serverConn.close()
            await listener.close()
        }
    }

    struct CleanUp {
        @Test
        func `Closing the listener ends a pending accept promptly`() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()

            // The 30-second timeout is far beyond `boundedOutcome`'s bound, so only the close can end the accept in time.
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: "dummy", timeout: 30)
            }

            // Give accept a moment to start, then close the listener
            try? await Task.sleep(for: .milliseconds(100))
            await listener.close()

            let outcome = try await boundedOutcome { _ = try await acceptTask.value }
            guard case let .failure(error)? = outcome, case let .acceptFailed(reason)? = error as? SOCKS5Listener.ListenerError else {
                Issue.record("Expected the accept to fail promptly, got \(String(describing: outcome))")
                return
            }
            #expect(reason == "The listener was closed")
            #expect(await acceptFailureReason(listener) == "Not listening")
        }

        @Test
        func `Closing an idle listener frees it`() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()
            await listener.close()
            #expect(await acceptFailureReason(listener) == "Not listening")
        }

        @Test
        func `A second concurrent accept is rejected`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()

            let firstAccept = Task {
                try await listener.accept(expectedDstAddr: "dummy", timeout: 30, handshakeTimeout: 30)
            }
            // A handshake held open proves the first accept is still running.
            let probe = try #require(SOCKS5GreetingProbe(host: "127.0.0.1", port: port))
            try #require(probe.awaitReply())
            #expect(await acceptFailureReason(listener) == "The listener is already waiting for a connection")

            await listener.close()
            let outcome = try await boundedOutcome { _ = try await firstAccept.value }
            #expect(outcome != nil)
            withExtendedLifetime(probe) {}
        }

        @Test
        func `An accept without a connection times out`() async throws {
            let listener = SOCKS5Listener()
            _ = try await listener.start()

            let outcome = try await boundedOutcome {
                _ = try await listener.accept(expectedDstAddr: "dummy", timeout: 0.3, handshakeTimeout: 30)
            }
            guard case let .failure(error)? = outcome, case let .acceptFailed(reason)? = error as? SOCKS5Listener.ListenerError else {
                Issue.record("Expected the accept to time out, got \(String(describing: outcome))")
                return
            }
            #expect(reason == "Accept timed out")
            await listener.close()
        }

        @Test
        func `Closing the listener ends a handshake the peer never finishes`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: "dummy", timeout: 30, handshakeTimeout: 30)
            }
            let probe = try #require(SOCKS5GreetingProbe(host: "127.0.0.1", port: port))
            try #require(probe.awaitReply())

            await listener.close()
            let outcome = try await boundedOutcome { _ = try await acceptTask.value }
            guard case let .failure(error)? = outcome, case let .acceptFailed(reason)? = error as? SOCKS5Listener.ListenerError else {
                Issue.record("Expected the accept to fail promptly, got \(String(describing: outcome))")
                return
            }
            #expect(reason == "The listener was closed")
            #expect(await acceptFailureReason(listener) == "Not listening")
            withExtendedLifetime(probe) {}
        }

        @Test
        func `A handshake the peer never finishes times out`() async throws {
            let listener = SOCKS5Listener()
            let port = try await listener.start()
            let acceptTask = Task {
                try await listener.accept(expectedDstAddr: "dummy", timeout: 30, handshakeTimeout: 0.3)
            }
            let probe = try #require(SOCKS5GreetingProbe(host: "127.0.0.1", port: port))
            try #require(probe.awaitReply())

            let outcome = try await boundedOutcome { _ = try await acceptTask.value }
            guard case let .failure(error)? = outcome, case let .acceptFailed(reason)? = error as? SOCKS5Listener.ListenerError else {
                Issue.record("Expected the accept to time out, got \(String(describing: outcome))")
                return
            }
            #expect(reason == "The other side did not complete the handshake in time")
            await listener.close()
            withExtendedLifetime(probe) {}
        }
    }
}
