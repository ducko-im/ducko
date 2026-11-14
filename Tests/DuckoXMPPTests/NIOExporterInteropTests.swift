import Foundation
import Testing
@testable import DuckoXMPP

/// Checks the `tls-exporter` binding against what OpenSSL's `s_server` exports for the same handshake.
struct NIOExporterInteropTests {
    private struct KeyingMaterial: Decodable {
        let keyingMaterial: String
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_OPENSSL"] != nil),
        arguments: ["tls13-aes128", "tls13-chacha20", "tls13-aes256", "tls13-hrr", "tls12"]
    )
    func `the exporter binding matches OpenSSL's exported value`(mode: String) async throws {
        let peer = try TransportTestPeer(mode: mode, scriptName: "exporter-peer")
        do {
            try await withNIOTestGroup { group in
                let transport = NIOTransport(group: group, trustRoots: [Array(peer.anchor)])
                do {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: peer.port, serverName: "localhost")
                    let bindings = await transport.channelBindings()
                    #expect(bindings[.tlsServerEndPoint].map(hexString) == peer.fingerprint)
                    let exported = try peer.nextValue(KeyingMaterial.self).keyingMaterial
                    if mode == "tls12" {
                        #expect(bindings[.tlsExporter] == nil)
                    } else {
                        #expect(bindings[.tlsExporter].map(hexString) == exported)
                    }
                } catch {
                    await transport.disconnect()
                    throw error
                }
                await transport.disconnect()
            }
            try await peer.expectSuccess()
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}
