import Darwin
import Logging

private let log = Logger(label: "im.ducko.xmpp.socks5")

/// SOCKS5 client connection for Jingle file transfer via XEP-0065 proxies.
///
/// Connects to a SOCKS5 proxy, performs the SOCKS5 handshake with the
/// XEP-0065 destination address (SHA-1 hash), and provides raw byte I/O.
actor SOCKS5Connection {
    // MARK: - Types

    /// Errors from the SOCKS5 connection.
    enum SOCKS5Error: Error {
        case connectionFailed(String)
        case handshakeFailed(String)
        case notConnected
        case alreadyConnected
        case sendFailed(String)
        case receiveFailed(String)

        var displayText: String {
            switch self {
            case let .connectionFailed(reason), let .handshakeFailed(reason), let .sendFailed(reason), let .receiveFailed(reason): reason
            case .notConnected: "The connection is not open"
            case .alreadyConnected: "The connection is already open"
            }
        }
    }

    // MARK: - State

    private var fd: Int32 = -1
    private var isConnecting = false
    private var inFlightOperations = 0
    private var closeRequested = false

    // MARK: - Static Helpers

    /// Computes the SOCKS5 destination address per XEP-0065 §5.3.2:
    /// `SHA1(SID + initiatorJID + targetJID)` as a 40-char lowercase hex string.
    nonisolated static func destinationAddress(
        sid: String,
        initiatorJID: String,
        targetJID: String
    ) -> String {
        let input = sid + initiatorJID + targetJID
        return sha1Hex(Array(input.utf8))
    }

    /// SOCKS5 greeting: version 5, 1 method, NO AUTH (0x00).
    nonisolated static let greetingBytes: [UInt8] = [0x05, 0x01, 0x00]

    /// Builds a SOCKS5 CONNECT request for a domain address.
    ///
    /// Format: `[VER=5, CMD=1, RSV=0, ATYP=3, LEN, ADDR..., PORT_HI=0, PORT_LO=0]`
    nonisolated static func connectRequest(
        destinationAddress: String
    ) -> [UInt8] {
        let addrBytes = Array(destinationAddress.utf8)
        var request: [UInt8] = [0x05, 0x01, 0x00, 0x03]
        request.append(UInt8(addrBytes.count))
        request.append(contentsOf: addrBytes)
        request.append(contentsOf: [0x00, 0x00]) // port = 0
        return request
    }

    /// Validates the SOCKS5 greeting response (server method selection).
    nonisolated static func validateGreetingResponse(
        _ response: [UInt8]
    ) throws {
        guard response.count == 2 else {
            throw SOCKS5Error.handshakeFailed(
                "Greeting response length \(response.count), expected 2"
            )
        }
        guard response[0] == 0x05 else {
            throw SOCKS5Error.handshakeFailed(
                "Greeting version \(response[0]), expected 5"
            )
        }
        guard response[1] == 0x00 else {
            throw SOCKS5Error.handshakeFailed(
                "Server rejected auth methods (method=\(response[1]))"
            )
        }
    }

    /// Validates the SOCKS5 CONNECT response.
    nonisolated static func validateConnectResponse(
        _ response: [UInt8]
    ) throws {
        guard response.count >= 2 else {
            throw SOCKS5Error.handshakeFailed(
                "Connect response too short (\(response.count) bytes)"
            )
        }
        guard response[0] == 0x05 else {
            throw SOCKS5Error.handshakeFailed(
                "Connect response version \(response[0]), expected 5"
            )
        }
        guard response[1] == 0x00 else {
            throw SOCKS5Error.handshakeFailed(replyText(response[1]))
        }
    }

    /// Readable text for a SOCKS5 CONNECT reply code (RFC 1928 §6).
    nonisolated static func replyText(_ code: UInt8) -> String {
        switch code {
        case 0x01: "General SOCKS server failure"
        case 0x02: "Connection not allowed by ruleset"
        case 0x03: "Network unreachable"
        case 0x04: "Host unreachable"
        case 0x05: "Connection refused"
        case 0x06: "TTL expired"
        case 0x07: "Command not supported"
        case 0x08: "Address type not supported"
        default: "Reply code \(code)"
        }
    }

    // MARK: - Public API

    /// Adopts an already-connected socket file descriptor for data transfer.
    /// Used by SOCKS5Listener after accepting and validating an incoming connection.
    func adopt(fd newFD: Int32) throws {
        guard fd == -1 else { throw SOCKS5Error.alreadyConnected }
        fd = newFD
    }

    /// Connects to a SOCKS5 proxy and performs the handshake, giving up after `timeout` seconds.
    func connect(
        host: String,
        port: UInt16,
        destinationAddress: String,
        timeout: Double = 10
    ) async throws {
        guard fd == -1, !isConnecting else { throw SOCKS5Error.alreadyConnected }

        isConnecting = true
        let deadline = ContinuousClock.now + .seconds(timeout)
        let result = await Task.detached {
            let socketFD = try Self.resolveAndConnect(host: host, port: port, until: deadline)
            do {
                try Self.performHandshake(fd: socketFD, destinationAddress: destinationAddress, until: deadline)
            } catch {
                Darwin.close(socketFD)
                throw error
            }
            return socketFD
        }.result
        isConnecting = false
        let closedDuringAttempt = closeRequested
        closeRequested = false

        let socketFD = try result.get()
        // A close() during the attempt wins: the new socket is released instead of kept.
        guard !closedDuringAttempt else {
            Darwin.close(socketFD)
            throw SOCKS5Error.notConnected
        }
        fd = socketFD
        log.info("SOCKS5 connected to \(host):\(port)")
    }

    /// Sends data over the established SOCKS5 connection. Given `stallTimeout`, it fails once the peer has taken no bytes
    /// for that long.
    func send(_ data: [UInt8], stallTimeout: Duration? = nil) async throws {
        let fdCopy = try beginOperation()
        let result = await Task.detached {
            try Self.sendAll(fd: fdCopy, data: data, stallTimeout: stallTimeout)
        }.result
        endOperation()
        try result.get()
    }

    /// Receives exactly `count` bytes from the connection. Given `stallTimeout`, it fails once the peer has sent no bytes
    /// for that long.
    func receive(_ count: Int, stallTimeout: Duration? = nil) async throws -> [UInt8] {
        let fdCopy = try beginOperation()
        let result = await Task.detached {
            try Self.recvAll(fd: fdCopy, count: count, stallTimeout: stallTimeout)
        }.result
        endOperation()
        return try result.get()
    }

    /// Closes the SOCKS5 connection. A send or receive still running is shut down first. The descriptor is released only
    /// once that operation returns, so it never acts on a reused descriptor.
    func close() {
        if isConnecting {
            closeRequested = true
        } else if fd >= 0, !closeRequested {
            if inFlightOperations > 0 {
                shutdown(fd, SHUT_RDWR)
                closeRequested = true
            } else {
                closeDescriptor()
            }
        }
    }

    // MARK: - Private: Descriptor Lifetime

    private func beginOperation() throws -> Int32 {
        guard fd >= 0, !closeRequested else { throw SOCKS5Error.notConnected }
        inFlightOperations += 1
        return fd
    }

    private func endOperation() {
        inFlightOperations -= 1
        if closeRequested, inFlightOperations == 0 {
            closeDescriptor()
        }
    }

    private func closeDescriptor() {
        Darwin.close(fd)
        fd = -1
        closeRequested = false
    }

    // MARK: - Private: Socket I/O

    private static func resolveAndConnect(
        host: String,
        port: UInt16,
        until deadline: ContinuousClock.Instant
    ) throws -> Int32 {
        do throws(TCPConnectError) {
            return try connectTCPSocket(host: host, port: port, deadline: deadline)
        } catch {
            throw SOCKS5Error.connectionFailed(error.reason)
        }
    }

    private static func performHandshake(
        fd: Int32,
        destinationAddress: String,
        until deadline: ContinuousClock.Instant
    ) throws {
        func receive(_ count: Int) throws -> [UInt8] {
            do throws(SocketWaitError) {
                return try receiveExactly(count, from: fd, until: deadline)
            } catch {
                throw handshakeError(error)
            }
        }

        try sendAll(fd: fd, data: greetingBytes)

        let greetingResponse = try receive(2)
        try validateGreetingResponse(greetingResponse)

        let request = connectRequest(destinationAddress: destinationAddress)
        try sendAll(fd: fd, data: request)

        // CONNECT response header: VER, REP, RSV, ATYP, first addr byte
        let header = try receive(5)
        try validateConnectResponse(header)

        let remaining = connectResponseRemainingBytes(header)
        if remaining > 0 {
            _ = try receive(remaining)
        }
    }

    private static func handshakeError(_ error: SocketWaitError) -> SOCKS5Error {
        switch error {
        case .timedOut, .woken: .handshakeFailed("The other side did not complete the handshake in time")
        case let .failed(code): .receiveFailed(posixErrorText(code))
        case .closed: .receiveFailed("The connection was closed")
        }
    }

    /// Determines how many more bytes to read after the 5-byte CONNECT response header.
    private static func connectResponseRemainingBytes(
        _ header: [UInt8]
    ) -> Int {
        guard header.count >= 5 else { return 0 }
        let atyp = header[3]
        switch atyp {
        case 0x01: // IPv4: 3 more addr bytes + 2 port bytes
            return 5
        case 0x03: // Domain: header[4] is length, then domain + 2 port bytes
            return Int(header[4]) + 2
        case 0x04: // IPv6: 15 more addr bytes + 2 port bytes
            return 17
        default:
            return 0
        }
    }

    /// Writes all of `data`. Given `stallTimeout`, the socket is non-blocking for the write, which waits for buffer space
    /// no longer than that, so a peer that stops reading fails the send instead of holding it forever. A blocking socket
    /// would not do: macOS `send` ignores `MSG_DONTWAIT`, and room for part of a write still blocks on the rest.
    static func sendAll(fd: Int32, data: [UInt8], stallTimeout: Duration? = nil) throws {
        let flags = fcntl(fd, F_GETFL)
        if stallTimeout != nil {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        defer {
            if stallTimeout != nil { _ = fcntl(fd, F_SETFL, flags) }
        }
        try data.withUnsafeBufferPointer { buf in
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(fd, buf.baseAddress! + totalSent, data.count - totalSent, 0)
                if sent < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK, let stallTimeout {
                        try awaitProgress(fd: fd, events: Int16(POLLOUT), stallTimeout: stallTimeout) {
                            .sendFailed($0 ?? "The other side stopped receiving the file")
                        }
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        continue
                    }
                    throw SOCKS5Error.sendFailed(posixErrorText(errno))
                }
                guard sent > 0 else {
                    throw SOCKS5Error.sendFailed("The connection was closed")
                }
                totalSent += sent
            }
        }
    }

    /// Reads exactly `count` bytes. Given `stallTimeout`, each read first waits for data no longer than that, so a peer
    /// that stops sending fails the receive instead of holding it forever.
    static func recvAll(fd: Int32, count: Int, stallTimeout: Duration? = nil) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { buf in
            while totalRead < count {
                if let stallTimeout {
                    try awaitProgress(fd: fd, events: Int16(POLLIN), stallTimeout: stallTimeout) {
                        .receiveFailed($0 ?? "The other side stopped sending the file")
                    }
                }
                let result = recv(
                    fd,
                    buf.baseAddress! + totalRead,
                    count - totalRead,
                    0
                )
                if result < 0 {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                        continue
                    }
                    throw SOCKS5Error.receiveFailed(posixErrorText(errno))
                }
                guard result > 0 else {
                    throw SOCKS5Error.receiveFailed("The connection was closed")
                }
                totalRead += result
            }
        }
        return buffer
    }

    /// Waits until `fd` reports `events`, failing with `failure(nil)` once `stallTimeout` passes without that, or with
    /// `failure(reason)` when the wait itself fails.
    private static func awaitProgress(
        fd: Int32, events: Int16, stallTimeout: Duration, failure: (String?) -> SOCKS5Error
    ) throws {
        do throws(SocketWaitError) {
            try waitForSocket(fd, events: events, until: .now + stallTimeout)
        } catch {
            switch error {
            case .timedOut: throw failure(nil)
            case let .failed(code): throw failure(posixErrorText(code))
            case .woken, .closed: throw failure("The connection was closed")
            }
        }
    }
}
