import Foundation
import Testing
@testable import DuckoXMPP

struct NIOProtocolVersionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_PYTHON"] != nil), arguments: ["tls12", "tls13", "tls11"])
    func `negotiated version matches the peer and rejects obsolete TLS`(mode: String) async throws {
        let peer = try TransportTestPeer(mode: mode)
        do {
            try await withNIOTestGroup { group in
                let transport: any XMPPTransport = ProcessInfo.processInfo.environment["DUCKO_TLS_INSTALLED_ROOT"] == "1"
                    ? makeDefaultXMPPTransport()
                    : NIOTransport(group: group, trustRoots: [Array(peer.anchor)])
                #expect(transport is NIOTransport)
                let connection = XMPPConnection(transport: transport)
                let reader = EventReader(connection.events)
                do {
                    try await connection.connectWithTLS(host: "127.0.0.1", port: peer.port, serverName: "localhost")
                    #expect(mode != "tls11")
                    let info = try #require(await connection.tlsInfo)
                    #expect(info.protocolVersion == (mode == "tls12" ? "TLS 1.2" : "TLS 1.3"))
                    #expect(info.wireVersion == (mode == "tls12" ? 0x0303 : 0x0304))
                    try await connection.send(XMPPStreamWriter.streamOpening(to: "localhost"))
                    _ = try await reader.awaitFeatures()
                    try await connection.send(Array("secure-probe".utf8))
                    let reply = try await reader.awaitStanza()
                    #expect(reply.child(named: "body")?.textContent == "secure-reply")
                } catch {
                    if mode == "tls11", case let XMPPClientError.tlsNegotiationFailed(reason) = error {
                        #expect(!reason.contains("in time"))
                        #expect(await connection.tlsInfo == nil)
                    } else {
                        await connection.disconnect()
                        throw error
                    }
                }
                await connection.disconnect()
                #expect(await connection.tlsInfo == nil)
            }
            try await peer.expectSuccess()
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}
