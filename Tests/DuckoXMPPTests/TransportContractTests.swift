import Darwin
import Dispatch
import DuckoTestSupport
import Foundation
import NIOCore
import Testing
@testable import DuckoXMPP

// MARK: - Helpers

private func bindLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(bindResult == 0)
    return try (fd, boundPort(of: fd))
}

private func listeningLoopbackSocket() throws -> (fd: Int32, port: UInt16) {
    let (fd, port) = try bindLoopbackSocket()
    try #require(listen(fd, 1) == 0)
    return (fd, port)
}

private func bindSocket(at address: addrinfo) throws -> (fd: Int32, port: UInt16) {
    let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
    try #require(fd >= 0)
    try #require(bind(fd, address.ai_addr, address.ai_addrlen) == 0)
    return try (fd, boundPort(of: fd))
}

private func socketAddress(
    of fd: Int32,
    _ query: (Int32, UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) -> Int32
) throws -> sockaddr_storage {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            query(fd, sa, &length)
        }
    }
    try #require(result == 0)
    return storage
}

/// Accepts one connection and reads the client's first bytes without ever replying, returning the accepted socket.
private func acceptWithoutReplying(on listenFD: Int32) -> Task<Int32, Never> {
    blockingTransportPeer {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return clientFD }
        disableSIGPIPE(clientFD)
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = recv(clientFD, &buffer, buffer.count, 0)
        return clientFD
    }
}

/// Connects `transport` to a loopback peer that doesn't read, with a receive window small enough that a large send
/// waits for the socket. Returns the accepted and listening sockets for the caller to close.
private func connectToNonReadingPeer(_ transport: any XMPPTransport) async throws -> (serverFD: Int32, listenFD: Int32) {
    let (listenFD, port) = try bindLoopbackSocket()
    var receiveBufferSize: Int32 = 4096
    setsockopt(listenFD, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, socklen_t(MemoryLayout<Int32>.size))
    try #require(listen(listenFD, 1) == 0)
    let accepted = blockingTransportPeer { accept(listenFD, nil, nil) }
    try await transport.connect(host: "127.0.0.1", port: port)
    let serverFD = await accepted.value
    try #require(serverFD >= 0)
    return (serverFD, listenFD)
}

private func boundPort(of fd: Int32) throws -> UInt16 {
    let storage = try socketAddress(of: fd, getsockname)
    // sin_port and sin6_port share the same offset, so reading through sockaddr_in covers both families.
    let port = withUnsafeBytes(of: storage) { $0.load(as: sockaddr_in.self).sin_port }
    return UInt16(bigEndian: port)
}

// MARK: - Tests

enum TransportContractTests {
    struct ErrorText {
        @Test
        func `posixErrorText renders errno as readable text`() {
            #expect(posixErrorText(ECONNREFUSED) == "Connection refused")
        }

        @Test
        func `addressInfoErrorText renders resolver errors as readable text`() {
            #expect(addressInfoErrorText(EAI_NONAME) == "nodename nor servname provided, or not known")
        }

        @Test
        func `addressInfoErrorText reports errno for system resolver errors`() {
            let text = { () -> String in
                errno = ECONNREFUSED
                return addressInfoErrorText(EAI_SYSTEM)
            }()
            #expect(text == "Connection refused")
        }
    }

    struct ConnectFailure {
        @Test
        func `Connecting to a closed port reports a readable reason`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (fd, port) = try bindLoopbackSocket()
                close(fd)

                let error = await #expect(throws: XMPPClientError.self) {
                    try await transport.connect(host: "127.0.0.1", port: port)
                }

                guard case let .connectionFailed(reason) = error else {
                    Issue.record("Expected connectionFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason == "The server could not be reached")
            }
        }
    }

    struct AddressFallback {
        @Test
        func `connectTCPSocket falls back to the next resolved address`() throws {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            try #require(getaddrinfo("localhost", "0", &hints, &result) == 0)
            let addrList = try #require(result)
            defer { freeaddrinfo(addrList) }

            let addresses = Array(sequence(first: addrList.pointee) { $0.ai_next?.pointee })
            let first = try #require(addresses.first)
            let last = try #require(addresses.last)
            // Two families guarantee an earlier address to fall back from, and let the peer family identify the last one.
            try #require(first.ai_family != last.ai_family)

            // Only the last address listens, so every earlier connect is refused.
            let (listenFD, port) = try bindSocket(at: last)
            defer { close(listenFD) }
            try #require(listen(listenFD, 1) == 0)

            let clientFD = try connectTCPSocket(host: "localhost", port: port)
            defer { close(clientFD) }

            let peerAddr = try socketAddress(of: clientFD, getpeername)
            #expect(Int32(peerAddr.ss_family) == last.ai_family)
        }
    }

    struct TLSFailure {
        @Test
        func `A non-TLS reply to the handshake reports a readable reason`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()

                // Reads the ClientHello before replying, so the transport's plain receive loop has already stopped
                // and can't consume the junk. The server then holds the socket open until the client disconnects,
                // so the client never writes into a closed peer.
                let server = blockingTransportPeer {
                    let clientFD = accept(listenFD, nil, nil)
                    guard clientFD >= 0 else { return }
                    disableSIGPIPE(clientFD)
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    _ = recv(clientFD, &buffer, buffer.count, 0)
                    let junk = Array("HTTP/1.1 400 Bad Request\r\n\r\n".utf8)
                    _ = Darwin.send(clientFD, junk, junk.count, 0)
                    while recv(clientFD, &buffer, buffer.count, 0) > 0 {}
                    close(clientFD)
                }

                try await transport.connect(host: "127.0.0.1", port: port)
                await transport.stopReceiving()
                let error = await #expect(throws: XMPPClientError.self) {
                    _ = try await transport.upgradeTLS(serverName: "localhost")
                }
                await transport.disconnect()
                await server.value
                close(listenFD)

                guard case let .tlsNegotiationFailed(reason) = error else {
                    Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                    return
                }
                #expect(!reason.isEmpty)
                #expect(!reason.hasPrefix("TLS handshake failed"))
                #expect(!reason.contains { $0.isNumber })
            }
        }

        @Test
        func `Upgrading while still reading is refused`() async throws {
            try await withTransport(handshakeTimeout: .milliseconds(100)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let server = blockingTransportPeer { accept(listenFD, nil, nil) }

                // A short handshake timeout means a handshake that did start would fail with a different reason.
                try await transport.connect(host: "127.0.0.1", port: port)
                let serverFD = await server.value
                let outcome = try await boundedOutcome {
                    _ = try await transport.upgradeTLS(serverName: "localhost")
                }
                await transport.disconnect()
                close(serverFD)
                close(listenFD)

                let result = try #require(outcome)
                let error = #expect(throws: XMPPClientError.self) { try result.get() }
                guard case let .tlsNegotiationFailed(reason) = error else {
                    Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason == "Reading had not stopped before the secure connection started")
            }
        }

        @Test
        func `Disconnecting during a TLS handshake ends the handshake`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()

                let server = acceptWithoutReplying(on: listenFD)

                let connectTask = Task {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
                }
                let serverFD = await server.value
                let disconnected = try await boundedOutcome { await transport.disconnect() }
                let outcome = try await boundedOutcome { try await connectTask.value }
                close(serverFD)
                close(listenFD)

                #expect(disconnected != nil)
                let result = try #require(outcome)
                #expect(throws: XMPPClientError.self) { try result.get() }
            }
        }

        @Test
        func `A server that never answers the TLS handshake times out`() async throws {
            try await withTransport(handshakeTimeout: .milliseconds(100)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let server = acceptWithoutReplying(on: listenFD)

                let outcome = try await boundedOutcome {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
                }
                await close(server.value)
                close(listenFD)

                let result = try #require(outcome)
                let error = #expect(throws: XMPPClientError.self) { try result.get() }
                guard case let .tlsNegotiationFailed(reason) = error else {
                    Issue.record("Expected tlsNegotiationFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason == "The server did not complete the TLS handshake in time")
            }
        }

        @Test
        func `Cancelling a TLS connect ends the handshake`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let server = acceptWithoutReplying(on: listenFD)

                let connectTask = Task {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
                }
                let serverFD = await server.value
                connectTask.cancel()
                let outcome = try await boundedOutcome { try await connectTask.value }
                close(serverFD)
                close(listenFD)

                let result = try #require(outcome)
                #expect(throws: CancellationError.self) { try result.get() }
            }
        }

        @Test(arguments: [false, true])
        func `Ending a TLS upgrade settles the pending handshake`(cancel: Bool) async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let server = acceptWithoutReplying(on: listenFD)
                try await transport.connect(host: "127.0.0.1", port: port)
                await transport.stopReceiving()
                let upgrade = Task { _ = try await transport.upgradeTLS(serverName: "localhost") }
                let serverFD = await server.value
                if cancel { upgrade.cancel() } else { await transport.disconnect() }
                let outcome = try await boundedOutcome { try await upgrade.value }
                close(serverFD)
                close(listenFD)

                let result = try #require(outcome)
                if cancel {
                    #expect(throws: CancellationError.self) { try result.get() }
                } else {
                    #expect(throws: XMPPClientError.self) { try result.get() }
                }
                #expect(await transport.tlsInfo == nil)
                #expect(await transport.channelBindings().isEmpty)
            }
        }
    }

    struct ReceivePhases {
        @Test
        func `Peer EOF delivers buffered bytes and finishes the stream`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                defer { close(listenFD) }
                let payload = Array("<presence/></stream:stream>".utf8)
                let server = blockingTransportPeer {
                    let clientFD = accept(listenFD, nil, nil)
                    guard clientFD >= 0 else { return false }
                    disableSIGPIPE(clientFD)
                    defer { close(clientFD) }
                    return Darwin.send(clientFD, payload, payload.count, 0) == payload.count
                }
                try await transport.connect(host: "127.0.0.1", port: port)
                let sent = await server.value
                #expect(sent)
                let stream = transport.receivedData
                let outcome = try await boundedOutcome {
                    var received: [UInt8] = []
                    for await chunk in stream {
                        received += chunk
                    }
                    #expect(received == payload)
                }
                let result = try #require(outcome)
                #expect(throws: Never.self) { try result.get() }
            }
        }

        @Test
        func `Stopping receipt finishes the receive stream`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let payload = Array(testProceed.utf8)
                // Sends the payload and holds the socket open, so only stopping receipt can end the stream.
                let server = blockingTransportPeer {
                    let clientFD = accept(listenFD, nil, nil)
                    if clientFD >= 0 {
                        disableSIGPIPE(clientFD)
                        _ = Darwin.send(clientFD, payload, payload.count, 0)
                    }
                    return clientFD
                }

                try await transport.connect(host: "127.0.0.1", port: port)
                let serverFD = await server.value
                let receivedData = transport.receivedData
                let outcome = try await boundedOutcome {
                    var iterator = receivedData.makeAsyncIterator()
                    var received: [UInt8] = []
                    while received.count < payload.count, let chunk = await iterator.next() {
                        received += chunk
                    }
                    await transport.stopReceiving()
                    guard received == payload, await iterator.next() == nil else {
                        throw XMPPClientError.unexpectedStreamState("The receive stream did not end after the payload")
                    }
                }
                await transport.disconnect()
                close(serverFD)
                close(listenFD)

                let result = try #require(outcome)
                #expect(throws: Never.self) { try result.get() }
            }
        }
    }

    struct SendFailure {
        @Test
        func `Sending on a reset connection reports a readable reason`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()

                let server = blockingTransportPeer { accept(listenFD, nil, nil) }

                try await transport.connect(host: "127.0.0.1", port: port)
                let serverFD = await server.value
                close(listenFD)
                try #require(serverFD >= 0)
                // Resetting only after connect returns keeps the reset from failing connect itself.
                // A zero linger timeout makes close send RST instead of FIN.
                var lingerOption = linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(serverFD, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
                close(serverFD)
                // The receive loop ends once it observes the reset, so the send below deterministically hits it.
                for await _ in transport.receivedData {}

                let error = await #expect(throws: XMPPClientError.self) {
                    try await transport.send(Array("<presence/>".utf8))
                }
                await transport.disconnect()

                guard case let .sendFailed(reason) = error else {
                    Issue.record("Expected sendFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason == "The connection closed before the data could be sent")
            }
        }

        @Test
        func `A send after a failed send still goes out`() async throws {
            try await withTransport(handshakeTimeout: .seconds(30)) { transport in
                let (listenFD, port) = try listeningLoopbackSocket()
                let accepted = blockingTransportPeer { accept(listenFD, nil, nil) }

                await #expect(throws: XMPPClientError.self) {
                    try await transport.send(Array("<early/>".utf8))
                }
                try await transport.connect(host: "127.0.0.1", port: port)
                let serverFD = await accepted.value
                try #require(serverFD >= 0)

                let stanza = Array("<presence/>".utf8)
                try await transport.send(stanza)
                var buffer = [UInt8](repeating: 0, count: 64)
                let count = recv(serverFD, &buffer, buffer.count, 0)
                await transport.disconnect()
                close(serverFD)
                close(listenFD)

                #expect(Array(buffer.prefix(max(count, 0))) == stanza)
            }
        }
    }

    struct StalledSend {
        @Test(arguments: [false, true])
        func `caller cancellation preserves accepted writes and the account connection`(cancelBeforeSend: Bool) async throws {
            try await withNonReadingPeer(operation: { transport, serverFD in
                let payload = [UInt8](repeating: 0x61, count: 8 << 20)
                let send = Task {
                    if cancelBeforeSend { withUnsafeCurrentTask { $0?.cancel() } }
                    try await transport.send(payload)
                }
                let early = try await boundedOutcome(timeout: .milliseconds(100)) { try await send.value }
                try #require(early == nil)
                var readable = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
                try #require(poll(&readable, 1, 1000) > 0)
                if !cancelBeforeSend { send.cancel() }
                let tail = Array("<presence/>".utf8)
                let reader = blockingTransportPeer { () -> [UInt8] in
                    var timeout = timeval(tv_sec: 3, tv_usec: 0)
                    setsockopt(serverFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var bytes: [UInt8] = []
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while bytes.count < payload.count + tail.count {
                        let count = recv(serverFD, &buffer, buffer.count, 0)
                        guard count > 0 else { break }
                        bytes.append(contentsOf: buffer[..<count])
                    }
                    return bytes
                }
                do {
                    try await send.value
                    try await transport.send(tail)
                    #expect(await reader.value == payload + tail)
                } catch {
                    await transport.disconnect()
                    _ = await reader.value
                    throw error
                }
            })
        }

        @Test
        func `Disconnecting during a stalled send ends the send`() async throws {
            try await withNonReadingPeer(operation: { transport, _ in
                let send = Task { try await transport.send([UInt8](repeating: 0x61, count: 8 << 20)) }
                let early = try await boundedOutcome(timeout: .milliseconds(100)) { try await send.value }
                try #require(early == nil)
                await transport.disconnect()
                let outcome = try await boundedOutcome { try await send.value }

                let result = try #require(outcome)
                let error = #expect(throws: XMPPClientError.self) { try result.get() }
                guard case .notConnected = error else {
                    Issue.record("Expected notConnected, got \(String(describing: error))")
                    return
                }
            })
        }

        @Test
        func `A send the peer never drains times out`() async throws {
            try await withNonReadingPeer(writeTimeout: .milliseconds(100), operation: { transport, _ in
                let outcome = try await boundedOutcome {
                    try await transport.send([UInt8](repeating: 0x61, count: 8 << 20))
                }
                await transport.disconnect()

                let result = try #require(outcome)
                let error = #expect(throws: XMPPClientError.self) { try result.get() }
                guard case let .sendFailed(reason) = error else {
                    Issue.record("Expected sendFailed, got \(String(describing: error))")
                    return
                }
                #expect(reason == "Timed out waiting to send data")
            })
        }
    }

    struct SendOrdering {
        @Test
        func `Concurrent sends that wait for the socket stay in order`() async throws {
            try await withNonReadingPeer(operation: { transport, serverFD in
                let payloadSize = 8 << 20
                let firstSend = Task { try await transport.send([UInt8](repeating: 0x61, count: payloadSize)) }
                // The first send is waiting for the socket before the second one starts, so the second's bytes could
                // interleave with the first's or go out ahead of them if writes weren't chained.
                let firstEarly = try await boundedOutcome(timeout: .milliseconds(100)) { try await firstSend.value }
                try #require(firstEarly == nil)
                let secondSend = Task { try await transport.send([UInt8](repeating: 0x62, count: payloadSize)) }
                let secondEarly = try await boundedOutcome(timeout: .milliseconds(50)) { try await secondSend.value }
                try #require(secondEarly == nil)

                let reader = blockingTransportPeer { () -> [UInt8] in
                    var received: [UInt8] = []
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    while received.count < 2 * payloadSize {
                        let count = recv(serverFD, &buffer, buffer.count, 0)
                        guard count > 0 else { break }
                        received.append(contentsOf: buffer[..<count])
                    }
                    return received
                }
                try await firstSend.value
                try await secondSend.value
                let received = await reader.value
                await transport.disconnect()

                try #require(received.count == 2 * payloadSize)
                let runs = zip(received, received.dropFirst()).count { $0 != $1 } + 1
                #expect(runs == 2)
                #expect(received.first == 0x61)
            })
        }
    }
}

private func withNonReadingPeer(
    writeTimeout: Duration = .seconds(5),
    operation: (any XMPPTransport, Int32) async throws -> Void
) async throws {
    try await withNIOTestGroup { group in
        let transport = NIOTransport(writeTimeout: writeTimeout, group: group)
        let (serverFD, listenFD) = try await connectToNonReadingPeer(transport)
        let outcome: Result<Void, any Error>
        do {
            try await operation(transport, serverFD)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await transport.disconnect()
        close(serverFD)
        close(listenFD)
        try outcome.get()
    }
}

private func withTransport(
    handshakeTimeout: Duration,
    operation: (any XMPPTransport) async throws -> Void
) async throws {
    try await withNIOTestGroup { group in
        let transport = NIOTransport(handshakeTimeout: handshakeTimeout, group: group)
        let outcome: Result<Void, any Error>
        do {
            try await operation(transport)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await transport.disconnect()
        try outcome.get()
    }
}

/// Blocking peer socket calls must not occupy the cooperative executor that drives the client.
private func blockingTransportPeer<Value: Sendable>(_ operation: @escaping @Sendable () -> Value) -> Task<Value, Never> {
    Task {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: operation()) }
        }
    }
}
