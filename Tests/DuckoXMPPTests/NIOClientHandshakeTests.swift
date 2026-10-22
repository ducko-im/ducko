import Foundation
import Testing
@testable import DuckoXMPP

struct NIOClientHandshakeTests {
    @Test(arguments: ["client-starttls", "client-direct", "client-forced", "client-plain", "client-refused", "client-contaminated", "client-untrusted"])
    func `real client authenticates only after permitted transport negotiation`(mode: String) async throws {
        try await exerciseTLSClient(mode: mode, useDefault: false)
    }

    @Test(arguments: ["registration", "registration-error", "registration-no-tls"])
    func `real registration retrieves a form before authentication`(mode: String) async throws {
        try await exerciseTLSRegistration(mode: mode, useDefault: false)
    }
}

struct NIODefaultClientHandshakeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_INSTALLED_ROOT"] == "1"), arguments: ["client-starttls", "client-direct", "client-forced"])
    func `production client authenticates against installed root`(mode: String) async throws {
        try await exerciseTLSClient(mode: mode, useDefault: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_INSTALLED_ROOT"] == "1"))
    func `production registration retrieves a controlled form`() async throws {
        try await exerciseTLSRegistration(mode: "registration", useDefault: true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_SRV_FIXTURE"] == "1"))
    func `production registration follows a direct TLS service record`() async throws {
        try await exerciseTLSRegistration(mode: "registration-direct", useDefault: true)
    }
}

private func exerciseTLSClient(mode: String, useDefault: Bool) async throws {
    let peer = try TransportTestPeer(mode: mode, scriptName: "xmpp-tls-peer")
    do {
        try await withNIOTestGroup { group in
            let transport: (any XMPPTransport)? = useDefault ? nil : NIOTransport(
                handshakeTimeout: .seconds(3), group: group, trustRoots: mode == "client-untrusted" ? [] : [Array(peer.anchor)]
            )
            let client = XMPPClient(domain: "localhost", credentials: .init(username: "alice", password: "local-fixture"), transport: transport, requireTLS: mode != "client-plain")
            let connected = group.next().makePromise(of: TLSInfo?.self)
            let events = Task {
                defer { connected.fail(CancellationError()) }
                for await event in client.events {
                    if case let .connected(jid) = event {
                        #expect(jid.description == "alice@localhost/fixture")
                        connected.succeed(client.tlsInfo)
                        return
                    }
                }
            }
            do {
                if mode == "client-direct" {
                    try await client.connectWithTLS(host: "127.0.0.1", port: peer.port)
                } else {
                    try await client.connect(host: "127.0.0.1", port: peer.port)
                }
                #expect(!["client-refused", "client-contaminated", "client-untrusted"].contains(mode))
                let info = try await connected.futureResult.get(timeout: .seconds(2))
                try expectClientMetadata(info, peer: peer, plaintext: mode == "client-plain")
            } catch {
                if mode == "client-refused", case XMPPClientError.tlsRequired = error {
                } else if mode == "client-contaminated", case XMPPClientError.tlsNegotiationFailed = error {
                    #expect(client.tlsInfo == nil)
                } else if mode == "client-untrusted", case XMPPClientError.untrustedCertificate(.notTrusted) = error {
                    #expect(client.tlsInfo == nil)
                } else {
                    events.cancel()
                    await client.disconnect()
                    await events.value
                    throw error
                }
            }
            events.cancel()
            await client.disconnect()
            await events.value
        }
        try await peer.expectSuccess()
    } catch {
        await peer.stop()
        throw error
    }
    await peer.stop()
}

private func expectClientMetadata(_ info: TLSInfo?, peer: TransportTestPeer, plaintext: Bool) throws {
    if plaintext {
        #expect(info == nil)
    } else {
        let info = try #require(info)
        #expect(info.certificateSHA256?.lowercased().replacingOccurrences(of: ":", with: "") == peer.fingerprint)
        #expect(info.certificateExpiry == peer.expiry)
        #expect(info.protocolVersion == peer.protocolVersion)
        #expect(info.cipherSuite == nil)
    }
}

private func exerciseTLSRegistration(mode: String, useDefault: Bool) async throws {
    let peer = try TransportTestPeer(mode: mode, scriptName: "xmpp-tls-peer")
    do {
        try await withNIOTestGroup { group in
            do {
                let form: RegistrationModule.RegistrationForm
                if useDefault {
                    form = try await XMPPRegistrationClient.retrieveForm(
                        domain: mode == "registration-direct" ? "registration.ducko.test" : "localhost",
                        host: mode == "registration-direct" ? nil : "127.0.0.1", port: peer.port
                    )
                } else {
                    let transport = NIOTransport(group: group, trustRoots: [Array(peer.anchor)])
                    form = try await XMPPRegistrationClient.retrieveForm(domain: "localhost", host: "127.0.0.1", port: peer.port, transport: transport)
                }
                #expect(mode == "registration" || mode == "registration-direct")
                #expect(form.legacyFields.map(\.name) == ["username", "password", "email"])
                #expect(form.instructions == "Local fixture")
            } catch {
                if mode == "registration-error", case XMPPRegistrationClient.RegistrationClientError.unexpectedResponse = error {
                } else if mode == "registration-no-tls", case XMPPRegistrationClient.RegistrationClientError.tlsNegotiationFailed = error {
                } else { throw error }
            }
        }
        try await peer.expectSuccess()
    } catch {
        await peer.stop()
        throw error
    }
    await peer.stop()
}
