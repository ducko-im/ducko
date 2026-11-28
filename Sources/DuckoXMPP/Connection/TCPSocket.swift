import Darwin

struct TCPConnectError: Error {
    let reason: String
}

/// Resolves `host` and connects a blocking TCP socket to the first reachable address. When `deadline` is set,
/// connecting gives up at it, but name resolution is not bounded. The socket has SIGPIPE disabled.
func connectTCPSocket(host: String, port: UInt16, deadline: ContinuousClock.Instant? = nil) throws(TCPConnectError) -> Int32 {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    let err = getaddrinfo(host, String(port), &hints, &result)
    guard err == 0, let addrList = result else {
        throw TCPConnectError(reason: addressLookupFailureText(err))
    }
    defer { freeaddrinfo(addrList) }

    var attemptErrors: [Int32] = []
    var addr: UnsafeMutablePointer<addrinfo>? = addrList
    while let ai = addr {
        let socketFD = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard socketFD >= 0 else {
            attemptErrors.append(errno)
            addr = ai.pointee.ai_next
            continue
        }
        disableSIGPIPE(socketFD)

        let connectError = connectSocket(socketFD, to: ai.pointee, until: deadline)
        if connectError == 0 {
            return socketFD
        }
        attemptErrors.append(connectError)
        close(socketFD)
        addr = ai.pointee.ai_next
    }
    throw TCPConnectError(reason: connectFailureText(errnoCodes: attemptErrors))
}

/// Connects `socketFD` to `address`, waiting no later than `deadline` when one is set. Returns 0 or the failure's errno.
private func connectSocket(_ socketFD: Int32, to address: addrinfo, until deadline: ContinuousClock.Instant?) -> Int32 {
    guard let deadline else {
        return Darwin.connect(socketFD, address.ai_addr, address.ai_addrlen) == 0 ? 0 : errno
    }
    let flags = fcntl(socketFD, F_GETFL)
    _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
    defer { _ = fcntl(socketFD, F_SETFL, flags) }

    guard Darwin.connect(socketFD, address.ai_addr, address.ai_addrlen) != 0 else { return 0 }
    guard errno == EINPROGRESS else { return errno }
    do throws(SocketWaitError) {
        try waitForSocket(socketFD, events: Int16(POLLOUT), until: deadline)
    } catch let .failed(code) {
        return code
    } catch {
        return ETIMEDOUT
    }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return errno }
    return socketError
}

/// Why a deadline-bounded socket wait or read gave up.
enum SocketWaitError: Error {
    /// The deadline passed.
    case timedOut
    /// The wake descriptor became readable: its owner is closing.
    case woken
    /// A system call failed with this errno.
    case failed(Int32)
    /// The peer closed the connection.
    case closed
}

/// Waits until `fd` reports `events`, failing at `deadline` or as soon as `wakeFD` becomes readable.
func waitForSocket(_ fd: Int32, events: Int16, wakeFD: Int32? = nil, until deadline: ContinuousClock.Instant) throws(SocketWaitError) {
    while true {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw .timedOut }
        let (seconds, attoseconds) = remaining.components
        let milliseconds = Int32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000 + 1)

        var pfds = [pollfd(fd: fd, events: events, revents: 0)]
        if let wakeFD {
            pfds.append(pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0))
        }
        let pollResult = poll(&pfds, nfds_t(pfds.count), milliseconds)
        if pollResult < 0 {
            guard errno == EINTR else { throw .failed(errno) }
            continue
        }
        if pfds.count > 1, pfds[1].revents != 0 { throw .woken }
        if pollResult > 0 { return }
    }
}

/// Reads exactly `count` bytes from `fd` before `deadline`, unless `wakeFD` becomes readable first.
func receiveExactly(_ count: Int, from fd: Int32, wakeFD: Int32? = nil, until deadline: ContinuousClock.Instant) throws(SocketWaitError) -> [UInt8] {
    var bytes: [UInt8] = []
    while bytes.count < count {
        try waitForSocket(fd, events: Int16(POLLIN), wakeFD: wakeFD, until: deadline)
        var chunk = [UInt8](repeating: 0, count: count - bytes.count)
        let received = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        if received < 0 {
            guard errno == EINTR || errno == EAGAIN else { throw .failed(errno) }
            continue
        }
        guard received > 0 else { throw .closed }
        bytes.append(contentsOf: chunk.prefix(received))
    }
    return bytes
}

/// Makes a send to a reset peer fail with `EPIPE` instead of raising SIGPIPE, which terminates the process by default.
func disableSIGPIPE(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
}
