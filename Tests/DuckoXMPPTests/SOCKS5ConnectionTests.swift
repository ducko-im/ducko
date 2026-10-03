import CryptoKit
import Darwin
import DuckoTestSupport
import Testing
@testable import DuckoXMPP

/// A loopback TCP socket bound to an ephemeral port, listening when `listens` is set; `nil` when setup fails.
private func loopbackSocket(listens: Bool) -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, !listens || listen(fd, 1) == 0 else {
        Darwin.close(fd)
        return nil
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return (fd, UInt16(bigEndian: address.sin_port))
}

enum SOCKS5ConnectionTests {
    struct DestinationAddressHash {
        @Test
        func `SHA-1 hash is 40-char lowercase hex`() {
            let result = SOCKS5Connection.destinationAddress(sid: "abc", initiatorJID: "a@b/c", targetJID: "d@e/f")
            #expect(result.count == 40)
            #expect(result == result.lowercased())
            let allHex = result.allSatisfy(\.isHexDigit)
            #expect(allHex)
        }

        @Test
        func `Deterministic — same inputs produce same output`() {
            let a = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@example.com/res", targetJID: "bob@example.com/res")
            let b = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@example.com/res", targetJID: "bob@example.com/res")
            #expect(a == b)
        }

        @Test
        func `Different inputs produce different hashes`() {
            let a = SOCKS5Connection.destinationAddress(sid: "sid-1", initiatorJID: "alice@a.com/r", targetJID: "bob@b.com/r")
            let b = SOCKS5Connection.destinationAddress(sid: "sid-2", initiatorJID: "alice@a.com/r", targetJID: "bob@b.com/r")
            #expect(a != b)
        }

        @Test
        func `Cross-check with CryptoKit SHA-1`() {
            let sid = "test-sid"
            let initiator = "user@example.com/abc"
            let target = "peer@example.com/xyz"
            let input = sid + initiator + target
            let digest = Insecure.SHA1.hash(data: Array(input.utf8))
            let expected = hexString(digest)

            let result = SOCKS5Connection.destinationAddress(sid: sid, initiatorJID: initiator, targetJID: target)
            #expect(result == expected)
        }
    }

    struct HandshakeByteSequence {
        @Test
        func `Greeting bytes are correct`() {
            let expected: [UInt8] = [0x05, 0x01, 0x00]
            #expect(SOCKS5Connection.greetingBytes == expected)
        }
    }

    struct ConnectRequestBytes {
        @Test
        func `Connect request has correct structure`() {
            let addr = "abcdef0123456789abcdef0123456789abcdef01"
            let request = SOCKS5Connection.connectRequest(destinationAddress: addr)

            #expect(request[0] == 0x05) // VER
            #expect(request[1] == 0x01) // CMD = CONNECT
            #expect(request[2] == 0x00) // RSV
            #expect(request[3] == 0x03) // ATYP = DOMAINNAME

            let addrLen = Int(request[4])
            #expect(addrLen == addr.utf8.count)

            let addrBytes = Array(request[5 ..< 5 + addrLen])
            #expect(addrBytes == Array(addr.utf8))

            // PORT = 0x0000
            #expect(request[5 + addrLen] == 0x00)
            #expect(request[5 + addrLen + 1] == 0x00)

            // Total length
            let expectedLen = 5 + addrLen + 2
            #expect(request.count == expectedLen)
        }
    }

    struct ResponseValidation {
        @Test
        func `validateGreetingResponse accepts valid response`() throws {
            try SOCKS5Connection.validateGreetingResponse([0x05, 0x00])
        }

        @Test
        func `validateGreetingResponse throws on rejected method`() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateGreetingResponse([0x05, 0xFF])
            }
        }

        @Test
        func `validateGreetingResponse throws on wrong length`() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateGreetingResponse([0x05])
            }
        }

        @Test
        func `validateConnectResponse accepts success reply`() throws {
            try SOCKS5Connection.validateConnectResponse([0x05, 0x00, 0x00, 0x01])
        }

        @Test
        func `validateConnectResponse throws on failure reply`() {
            #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateConnectResponse([0x05, 0x01, 0x00, 0x01])
            }
        }

        @Test
        func `validateConnectResponse reports the reply code as readable text`() {
            let error = #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.validateConnectResponse([0x05, 0x05, 0x00, 0x01])
            }
            guard case let .handshakeFailed(reason) = error else {
                Issue.record("Expected handshakeFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Connection refused")
        }

        @Test(arguments: [
            (UInt8(0x01), "General SOCKS server failure"),
            (UInt8(0x02), "Connection not allowed by ruleset"),
            (UInt8(0x03), "Network unreachable"),
            (UInt8(0x04), "Host unreachable"),
            (UInt8(0x05), "Connection refused"),
            (UInt8(0x06), "TTL expired"),
            (UInt8(0x07), "Command not supported"),
            (UInt8(0x08), "Address type not supported"),
            (UInt8(0x42), "Reply code 66")
        ])
        func `replyText renders reply codes as readable text`(code: UInt8, expected: String) {
            #expect(SOCKS5Connection.replyText(code) == expected)
        }
    }

    struct ErrorDisplayText {
        @Test(arguments: [
            (SOCKS5Connection.SOCKS5Error.connectionFailed("Connection refused"), "Connection refused"),
            (SOCKS5Connection.SOCKS5Error.handshakeFailed("General SOCKS server failure"), "General SOCKS server failure"),
            (SOCKS5Connection.SOCKS5Error.notConnected, "The connection is not open"),
            (SOCKS5Connection.SOCKS5Error.alreadyConnected, "The connection is already open"),
            (SOCKS5Connection.SOCKS5Error.sendFailed("Broken pipe"), "Broken pipe"),
            (SOCKS5Connection.SOCKS5Error.receiveFailed("Connection reset by peer"), "Connection reset by peer")
        ])
        func `Display text is readable`(error: SOCKS5Connection.SOCKS5Error, expected: String) {
            #expect(error.displayText == expected)
        }
    }

    struct SocketErrorText {
        @Test
        func `sendAll reports errno as readable text`() {
            let error = #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.sendAll(fd: -1, data: [1])
            }
            guard case let .sendFailed(reason) = error else {
                Issue.record("Expected sendFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Bad file descriptor")
        }

        @Test
        func `recvAll reports errno as readable text`() {
            let error = #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try SOCKS5Connection.recvAll(fd: -1, count: 1)
            }
            guard case let .receiveFailed(reason) = error else {
                Issue.record("Expected receiveFailed, got \(String(describing: error))")
                return
            }
            #expect(reason == "Bad file descriptor")
        }
    }

    struct AdoptFileDescriptor {
        @Test
        func `Send and receive work after adopt(fd:)`() async throws {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                Issue.record("socketpair() failed")
                return
            }

            let connA = SOCKS5Connection()
            try await connA.adopt(fd: fds[0])

            let connB = SOCKS5Connection()
            try await connB.adopt(fd: fds[1])

            let testData: [UInt8] = [1, 2, 3, 4, 5]
            try await connA.send(testData)
            let received = try await connB.receive(testData.count)
            #expect(received == testData)

            await connA.close()
            await connB.close()
        }

        @Test
        func `adopt(fd:) throws when already connected`() async throws {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                Issue.record("socketpair() failed")
                return
            }
            defer {
                Darwin.close(fds[1])
            }

            let conn = SOCKS5Connection()
            try await conn.adopt(fd: fds[0])

            await #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try await conn.adopt(fd: fds[1])
            }

            await conn.close()
        }
    }

    struct BoundedLifetime {
        @Test
        func `Closing ends a pending receive and frees the connection`() async throws {
            var fds: [Int32] = [0, 0]
            try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            defer { Darwin.close(fds[1]) }
            let connection = SOCKS5Connection()
            try await connection.adopt(fd: fds[0])

            let receiveTask = Task { try await connection.receive(1) }
            try await Task.sleep(for: .milliseconds(100))
            await connection.close()

            let outcome = try await boundedOutcome { _ = try await receiveTask.value }
            guard case .failure? = outcome else {
                Issue.record("Expected the receive to fail promptly, got \(String(describing: outcome))")
                return
            }
            await #expect(throws: SOCKS5Connection.SOCKS5Error.self) {
                try await connection.send([1])
            }
        }

        @Test
        func `A connect whose peer never answers the handshake times out`() async throws {
            let server = try #require(loopbackSocket(listens: true))
            defer { Darwin.close(server.fd) }

            let outcome = try await boundedOutcome {
                try await SOCKS5Connection().connect(host: "127.0.0.1", port: server.port, destinationAddress: "dummy", timeout: 0.3)
            }
            guard case let .failure(error)? = outcome, case let .handshakeFailed(reason)? = error as? SOCKS5Connection.SOCKS5Error else {
                Issue.record("Expected the handshake to time out, got \(String(describing: outcome))")
                return
            }
            #expect(reason == "The other side did not complete the handshake in time")
        }

        @Test
        func `A connect that never completes times out`() async throws {
            // A bound socket that never listens leaves a loopback connect waiting instead of refusing it.
            let unreachable = try #require(loopbackSocket(listens: false))
            defer { Darwin.close(unreachable.fd) }

            let outcome = try await boundedOutcome {
                try await SOCKS5Connection().connect(host: "127.0.0.1", port: unreachable.port, destinationAddress: "dummy", timeout: 0.3)
            }
            guard case let .failure(error)? = outcome, case let .connectionFailed(reason)? = error as? SOCKS5Connection.SOCKS5Error else {
                Issue.record("Expected the connect to time out, got \(String(describing: outcome))")
                return
            }
            #expect(reason == posixErrorText(ETIMEDOUT))
        }
    }

    struct CandidateSorting {
        @Test
        func `Candidates sorted by priority descending`() {
            let candidates = [
                SOCKS5Transport.Candidate(cid: "low", host: "a", port: 1, jid: "a@b", priority: 10, type: .proxy),
                SOCKS5Transport.Candidate(cid: "high", host: "b", port: 2, jid: "b@c", priority: 100, type: .proxy),
                SOCKS5Transport.Candidate(cid: "mid", host: "c", port: 3, jid: "c@d", priority: 50, type: .direct)
            ]
            let sorted = candidates.sorted { $0.priority > $1.priority }
            #expect(sorted[0].cid == "high")
            #expect(sorted[1].cid == "mid")
            #expect(sorted[2].cid == "low")
        }

        @Test
        func `Direct candidates have higher priority than proxy`() {
            let direct = SOCKS5Transport.Candidate(cid: "d1", host: "192.168.1.1", port: 5000, jid: "me@example.com", priority: 101, type: .direct)
            let proxy = SOCKS5Transport.Candidate(cid: "p1", host: "proxy.example.com", port: 1080, jid: "proxy@example.com", priority: 10, type: .proxy)
            let sorted = [proxy, direct].sorted { $0.priority > $1.priority }
            #expect(sorted[0].type == .direct)
            #expect(sorted[1].type == .proxy)
        }
    }
}
