import Darwin
import Logging

private let log = Logger(label: "im.ducko.xmpp.socks5listener")

/// SOCKS5 listening server for direct Jingle transport candidates (XEP-0260). Accepts one connection on an ephemeral port and returns a validated `SOCKS5Connection`.
actor SOCKS5Listener {
    // MARK: - Types

    /// Errors from the SOCKS5 listener.
    enum ListenerError: Error {
        case alreadyListening
        case socketCreationFailed(String)
        case bindFailed(String)
        case listenFailed(String)
        case acceptFailed(String)
        case handshakeFailed(String)
    }

    // MARK: - State

    private var listenFD: Int32 = -1
    /// Pipe whose write end `close()` uses to wake an `accept` blocked in `poll`, since closing a listening socket does not wake it.
    private var wakeFDs: (read: Int32, write: Int32) = (-1, -1)
    private var isAccepting = false
    private var closeRequested = false

    // MARK: - Public API

    /// Starts listening on an ephemeral port.
    /// - Returns: The port number assigned by the OS.
    func start() throws -> UInt16 {
        guard listenFD == -1 else { throw ListenerError.alreadyListening }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError.socketCreationFailed(posixErrorText(errno)) }

        // Allow address reuse
        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to INADDR_ANY on port 0 (ephemeral)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ListenerError.bindFailed(posixErrorText(err))
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ListenerError.listenFailed(posixErrorText(err))
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ListenerError.listenFailed(posixErrorText(err))
        }
        wakeFDs = (pipeFDs[0], pipeFDs[1])

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &addrLen)
            }
        }

        listenFD = fd
        let port = UInt16(bigEndian: boundAddr.sin_port)
        log.info("SOCKS5 listener started on port \(port)")
        return port
    }

    /// Waits for one incoming connection, validates the SOCKS5 handshake against `expectedDstAddr` (SHA-1 hash), and
    /// returns a `SOCKS5Connection`. Times out after `timeout` seconds without a connection or `handshakeTimeout` seconds
    /// into the handshake. `close()` ends it at any point.
    func accept(expectedDstAddr: String, timeout: Double = 60, handshakeTimeout: Double = 10) async throws -> SOCKS5Connection {
        guard listenFD >= 0 else {
            throw ListenerError.acceptFailed("Not listening")
        }
        // One accept at a time: close() leaves the descriptors open until the pending accept returns.
        guard !isAccepting else {
            throw ListenerError.acceptFailed("The listener is already waiting for a connection")
        }

        let fd = listenFD
        let wakeFD = wakeFDs.read
        let dstAddr = expectedDstAddr

        isAccepting = true
        let result = await Task.detached {
            do throws(SocketWaitError) {
                try waitForSocket(fd, events: Int16(POLLIN), wakeFD: wakeFD, until: .now + .seconds(timeout))
            } catch {
                throw Self.listenerError(error, timeoutText: "Accept timed out")
            }

            // Accept incoming connection (returns immediately since poll confirmed readiness)
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let acceptedFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(fd, sa, &clientAddrLen)
                }
            }

            guard acceptedFD >= 0 else {
                throw SOCKS5Listener.ListenerError.acceptFailed(posixErrorText(errno))
            }
            disableSIGPIPE(acceptedFD)

            do {
                try Self.performServerHandshake(
                    fd: acceptedFD, expectedDstAddr: dstAddr, wakeFD: wakeFD, deadline: .now + .seconds(handshakeTimeout)
                )
            } catch {
                Darwin.close(acceptedFD)
                throw error
            }

            let connection = SOCKS5Connection()
            try await connection.adopt(fd: acceptedFD)
            return connection
        }.result
        isAccepting = false
        if closeRequested {
            closeDescriptors()
        }
        return try result.get()
    }

    /// Closes the listening socket, ending a pending `accept`.
    func close() {
        guard listenFD >= 0 else { return }
        if isAccepting {
            // The pending accept closes the descriptors once it returns, so its poll never watches a reused descriptor.
            var byte: UInt8 = 0
            _ = write(wakeFDs.write, &byte, 1)
            closeRequested = true
        } else {
            closeDescriptors()
        }
    }

    private func closeDescriptors() {
        Darwin.close(listenFD)
        Darwin.close(wakeFDs.read)
        Darwin.close(wakeFDs.write)
        listenFD = -1
        wakeFDs = (-1, -1)
        closeRequested = false
    }

    // MARK: - Private: Errors

    /// `timeoutText` names the step that ran out of time.
    private static func listenerError(_ error: SocketWaitError, timeoutText: String) -> ListenerError {
        switch error {
        case .timedOut: .acceptFailed(timeoutText)
        case .woken: .acceptFailed("The listener was closed")
        case let .failed(code): .acceptFailed(posixErrorText(code))
        case .closed: .handshakeFailed("The connection was closed")
        }
    }

    // MARK: - Private: Server Handshake

    /// Performs the SOCKS5 server-side handshake on an accepted socket.
    private static func performServerHandshake(
        fd: Int32,
        expectedDstAddr: String,
        wakeFD: Int32,
        deadline: ContinuousClock.Instant
    ) throws {
        func receive(_ count: Int) throws -> [UInt8] {
            do throws(SocketWaitError) {
                return try receiveExactly(count, from: fd, wakeFD: wakeFD, until: deadline)
            } catch {
                throw listenerError(error, timeoutText: "The other side did not complete the handshake in time")
            }
        }

        // 1. Receive client greeting header (2 bytes: VER, NMETHODS)
        let greetingHeader = try receive(2)
        guard greetingHeader[0] == 0x05, greetingHeader[1] > 0 else {
            throw ListenerError.handshakeFailed(
                "Invalid greeting header: \(greetingHeader)"
            )
        }

        let methods = try receive(Int(greetingHeader[1]))
        guard methods.contains(0x00) else {
            // Send method rejection (0xFF = no acceptable methods)
            try SOCKS5Connection.sendAll(fd: fd, data: [0x05, 0xFF])
            throw ListenerError.handshakeFailed(
                "No acceptable auth method (no-auth not offered)"
            )
        }

        // 2. Send greeting response: NO AUTH accepted
        try SOCKS5Connection.sendAll(fd: fd, data: [0x05, 0x00])

        // 3. Receive CONNECT request header (4 bytes: VER, CMD, RSV, ATYP)
        let header = try receive(4)
        guard header[0] == 0x05, header[1] == 0x01, header[3] == 0x03 else {
            throw ListenerError.handshakeFailed(
                "Invalid CONNECT request header: \(header)"
            )
        }

        // 4. Read domain address length + address + port
        let addrLenBytes = try receive(1)
        let addrLen = Int(addrLenBytes[0])
        let addrBytes = try receive(addrLen)
        _ = try receive(2) // port (ignored)

        // 5. Validate DST.ADDR (hex string — ASCII safe)
        let receivedAddr = String(decoding: addrBytes, as: UTF8.self)
        guard receivedAddr == expectedDstAddr else {
            throw ListenerError.handshakeFailed(
                "DST.ADDR mismatch: expected \(expectedDstAddr), got \(receivedAddr)"
            )
        }

        // 6. Send success response
        let response: [UInt8] = [
            0x05, 0x00, 0x00, 0x01,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00
        ]
        try SOCKS5Connection.sendAll(fd: fd, data: response)

        log.info("SOCKS5 server handshake completed for \(expectedDstAddr)")
    }
}
