import Darwin
import NIOCore
import NIOPosix
import Testing
@testable import DuckoXMPP

struct NIOLifecycleTests {
    @Test(arguments: [false, true])
    func `attempt cancellation closes channels registered before or after cancellation`(cancelFirst: Bool) async throws {
        try await withNIOTestGroup { group in
            let channel = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
            let owner = NIOConnectionAttempt(eventLoop: channel.eventLoop)
            do {
                try #require(channel.isActive)
                if cancelFirst {
                    owner.cancel()
                    #expect(throws: XMPPClientError.self) { try owner.register(channel) }
                } else {
                    try owner.register(channel)
                    #expect(channel.isActive)
                    owner.cancel()
                }
                try await channel.closeFuture.get(timeout: .seconds(1))
                #expect(!channel.isActive)
                await #expect(throws: XMPPClientError.self) { try await owner.connected.futureResult.get() }
            } catch {
                owner.cancel()
                try? await channel.close()
                throw error
            }
        }
    }

    @Test
    func `a pending TCP connection expires with a timeout`() async throws {
        try await withNIOTestGroup { group in
            let (listener, port) = try lifecycleListener(listen: false)
            defer { close(listener) }
            let transport = NIOTransport(connectTimeout: .milliseconds(250), group: group)
            let start = ContinuousClock.now
            let error = await #expect(throws: XMPPClientError.self) {
                try await transport.connect(host: "127.0.0.1", port: port)
            }
            await transport.disconnect()
            #expect(ContinuousClock.now - start >= .milliseconds(200))
            guard case .timeout = error else {
                Issue.record("Expected TCP timeout, got \(String(describing: error))")
                return
            }
            #expect(await transport.tlsInfo == nil)
        }
    }

    @Test(arguments: [1, 4])
    func `disconnect releases sockets for independent accounts`(parallel: Int) async throws {
        try await withNIOTestGroup { group in
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for _ in 0 ..< parallel {
                    tasks.addTask { try await roundTrip(group: group) }
                }
                try await tasks.waitForAll()
            }
        }
    }

    private func roundTrip(group: any EventLoopGroup) async throws {
        let (listener, port) = try lifecycleListener()
        defer { close(listener) }
        let peer = Task.detached {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 3000) > 0 else { return Int32(-1) }
            let fd = accept(listener, nil, nil)
            if fd >= 0 { disableSIGPIPE(fd) }
            return fd
        }
        let transport = NIOTransport(group: group)
        do {
            try await transport.connect(host: "localhost", port: port)
        } catch {
            await transport.disconnect()
            let fd = await peer.value
            if fd >= 0 { close(fd) }
            throw error
        }
        let fd = await peer.value
        guard fd >= 0 else {
            await transport.disconnect()
            Issue.record("The listener did not accept the connection")
            return
        }
        defer { close(fd) }
        await transport.disconnect()
        await transport.disconnect()
        var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        try #require(poll(&waiting, 1, 1000) > 0)
        var byte: UInt8 = 0
        #expect(recv(fd, &byte, 1, 0) == 0)
        #expect(await transport.tlsInfo == nil)
        #expect(await transport.channelBindings().isEmpty)
    }
}

private func lifecycleListener(listen shouldListen: Bool = true) throws -> (Int32, UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    do {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        try #require(bound == 0)
        if shouldListen { try #require(listen(fd, 4) == 0) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        try #require(named == 0)
        return (fd, UInt16(bigEndian: address.sin_port))
    } catch {
        close(fd)
        throw error
    }
}
