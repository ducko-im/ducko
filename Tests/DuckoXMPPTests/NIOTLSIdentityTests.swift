import Foundation
import Security
import Testing
@testable import DuckoXMPP

struct NIOTLSIdentityTests {
    @Test
    func `issuer attributes read from most to least specific`() {
        let attributes: [[String: Any]] = ["US", "Let's Encrypt", "R11"].map { [kSecPropertyKeyValue as String: $0] }
        #expect(readableDistinguishedName(attributes) == "R11, Let's Encrypt, US")
    }

    @Test(arguments: [
        (errSecHostNameMismatch, CertificateTrustFailure.nameMismatch),
        (errSecCertificateExpired, .outsideValidityPeriod),
        (errSecCertificateNotValidYet, .outsideValidityPeriod),
        (errSecCreateChainFailed, .notTrusted),
        (errSecNotTrusted, .notTrusted)
    ])
    func `a rejected certificate's status names why it was not trusted`(status: OSStatus, reason: CertificateTrustFailure) {
        #expect(certificateTrustFailure(forStatus: Int(status)) == reason)
    }

    @Test(arguments: ["direct", "wronghost"])
    func `server identity and displayed certificate match the requested XMPP host`(mode: String) async throws {
        let peer = try TransportTestPeer(mode: mode)
        do {
            try await withNIOTestGroup { group in
                let transport = NIOTransport(handshakeTimeout: .seconds(3), group: group, trustRoots: [Array(peer.anchor)])
                do {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: peer.port, serverName: mode == "wronghost" ? "wrong.invalid" : "localhost")
                    #expect(mode == "direct")
                    let info = try #require(await transport.tlsInfo)
                    #expect(info.certificateSubject == "localhost")
                    #expect(info.certificateSHA256?.lowercased().replacingOccurrences(of: ":", with: "") == peer.fingerprint)
                    #expect(info.certificateExpiry == peer.expiry)
                    #expect(info.certificateIssuer == "Ducko local TLS test root")
                    try await transport.send(XMPPStreamWriter.streamOpening(to: "localhost"))
                    var iterator = transport.receivedData.makeAsyncIterator()
                    _ = try #require(await iterator.next())
                    try await transport.send(Array("secure-probe".utf8))
                    _ = try #require(await iterator.next())
                } catch {
                    if mode == "wronghost" {
                        guard case XMPPClientError.untrustedCertificate(.nameMismatch) = error else {
                            await transport.disconnect()
                            throw error
                        }
                        #expect(await transport.tlsInfo == nil)
                        #expect(await transport.channelBindingData() == nil)
                    } else {
                        await transport.disconnect()
                        throw error
                    }
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
