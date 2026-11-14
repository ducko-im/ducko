import NIOCore
import NIOPosix
import NIOSSL
import struct os.OSAllocatedUnfairLock
import Testing
@testable import DuckoXMPP

/// Runs a TLS 1.3 handshake against an in-process NIOSSL server, so the key-log capture is checked on every test run,
/// without `DUCKO_TLS_OPENSSL`.
struct NIOExporterCaptureTests {
    @Test
    func `a TLS 1.3 handshake carries the exporter binding of the server's exporter secret`() async throws {
        let peer = try TransportTestPeer(mode: "identity", scriptName: "exporter-peer")
        await peer.stop()
        let certificate = try #require(peer.certificate)
        let key = try #require(peer.key)
        let serverSecret = OSAllocatedUnfairLock(initialState: ExporterSecretCapture.none)
        var configuration = try TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(NIOSSLCertificate(bytes: Array(certificate.utf8), format: .pem))],
            privateKey: .privateKey(NIOSSLPrivateKey(bytes: Array(key.utf8), format: .pem))
        )
        configuration.minimumTLSVersion = .tlsv13
        configuration.keyLogCallback = { line in serverSecret.withLock { $0.record(exporterSecret(fromKeyLogLine: line)) } }
        let context = try NIOSSLContext(configuration: configuration)

        try await withNIOTestGroup { group in
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            let transport = NIOTransport(group: group, trustRoots: [Array(peer.anchor)])
            do {
                let port = try UInt16(#require(server.localAddress?.port))
                try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
                guard case let .captured(secret) = serverSecret.withLock({ $0 }) else {
                    throw XMPPClientError.unexpectedStreamState("The server logged no single exporter secret")
                }
                let exporter = try #require(tlsExporterChannelBinding(exporterSecret: secret))
                #expect(await transport.channelBindings()[.tlsExporter] == exporter)
            } catch {
                await transport.disconnect()
                try? await server.close()
                throw error
            }
            await transport.disconnect()
            try await server.close()
        }
    }
}
