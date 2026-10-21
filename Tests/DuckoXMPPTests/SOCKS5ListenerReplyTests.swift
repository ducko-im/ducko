import Darwin
import Testing
@testable import DuckoXMPP

struct SOCKS5ListenerReplyTests {
    /// XEP-0065 §5.3.2: the success reply's BND.ADDR and BND.PORT are the DST.ADDR and DST.PORT the request named.
    @Test
    func `The listener's reply echoes the requested address and port`() async throws {
        let listener = SOCKS5Listener()
        let port = try await listener.start()
        let accepted = Task { try await listener.accept(expectedDstAddr: "requested-address", timeout: 5) }

        let fd = try connectTCPSocket(host: "127.0.0.1", port: port)
        defer { Darwin.close(fd) }
        let address = Array("requested-address".utf8)
        let target = [UInt8(address.count)] + address + [0x1F, 0x90]
        try SOCKS5Connection.sendAll(fd: fd, data: SOCKS5Connection.greetingBytes)
        #expect(try SOCKS5Connection.recvAll(fd: fd, count: 2, stallTimeout: .seconds(2)) == [0x05, 0x00])
        try SOCKS5Connection.sendAll(fd: fd, data: [0x05, 0x01, 0x00, 0x03] + target)
        let reply = try SOCKS5Connection.recvAll(fd: fd, count: 4 + target.count, stallTimeout: .seconds(2))

        #expect(reply == [0x05, 0x00, 0x00, 0x03] + target)
        try await accepted.value.close()
        await listener.close()
    }
}
