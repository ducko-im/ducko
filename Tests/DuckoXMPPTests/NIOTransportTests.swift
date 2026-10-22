import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import DuckoXMPP

struct NIOTransportTests {
    @Test(arguments: ["ip-direct", "ip-starttls", "ip-override", "ip-wrong", "ip-dns-only", "ip-untrusted", "ip-dns-account"])
    func `IP account verification retains account identity across host overrides`(scenario: String) async throws {
        try await withNIOTestGroup { group in
            let peer = try TransportTestPeer(mode: scenario)
            let rejected = ["ip-wrong", "ip-dns-only", "ip-untrusted", "ip-dns-account"].contains(scenario)
            let serverName = scenario == "ip-override" ? "127.0.0.2" : (scenario == "ip-dns-account" ? "localhost" : "127.0.0.1")
            let transport = NIOTransport(handshakeTimeout: .seconds(3), group: group, trustRoots: scenario == "ip-untrusted" ? [] : [Array(peer.anchor)])
            let connection = XMPPConnection(transport: transport)
            let reader = EventReader(connection.events)
            do {
                do {
                    try await exerciseNIOExchange(mode: scenario == "ip-starttls" ? "starttls" : "direct", port: peer.port, connection: connection, reader: reader, serverName: serverName)
                    #expect(!rejected)
                } catch {
                    guard rejected, case let XMPPClientError.untrustedCertificate(reason) = error else { throw error }
                    #expect(reason == (scenario == "ip-untrusted" ? .notTrusted : .nameMismatch))
                    #expect(await connection.tlsInfo == nil)
                    #expect(await connection.channelBindingData == nil)
                }
                await connection.disconnect()
                try await peer.expectSuccess()
            } catch {
                await connection.disconnect()
                await peer.stop()
                throw error
            }
            await peer.stop()
        }
    }

    @Test(arguments: ["direct", "starttls"])
    func `failed direct TLS candidate leaves reception available for the next server`(nextMode: String) async throws {
        try await withNIOTestGroup { group in
            let rejected = try TransportTestPeer(mode: "wronghost")
            let healthy: TransportTestPeer
            do { healthy = try TransportTestPeer(mode: nextMode) } catch {
                await rejected.stop()
                throw error
            }
            let transport = NIOTransport(group: group, trustRoots: [Array(rejected.anchor), Array(healthy.anchor)])
            let connection = XMPPConnection(transport: transport)
            let reader = EventReader(connection.events)
            do {
                let error = await #expect(throws: XMPPClientError.self) {
                    try await connection.connectWithTLS(host: "127.0.0.1", port: rejected.port, serverName: "wrong.invalid")
                }
                guard case .untrustedCertificate(.nameMismatch) = error else {
                    throw XMPPClientError.unexpectedStreamState("The first peer did not fail TLS verification")
                }
                try await rejected.expectSuccess()
                try await exerciseNIOExchange(mode: nextMode, port: healthy.port, connection: connection, reader: reader)
                await connection.disconnect()
                try await healthy.expectSuccess()
            } catch {
                await connection.disconnect()
                await rejected.stop()
                await healthy.stop()
                throw error
            }
            await rejected.stop()
            await healthy.stop()
        }
    }

    @Test(arguments: ["starttls", "split", "direct", "plaintext", "retry", "contaminated", "stalledtls", "untrusted"])
    func `existing connection owns transport negotiation`(mode: String) async throws {
        try await exerciseNIOConnection(mode: mode)
    }

    @Test(arguments: ["stopplain", "stoptls"])
    func `stopping receipt drains its stream and preserves writes`(mode: String) async throws {
        try await withNIOTestGroup { group in
            let peer = try TransportTestPeer(mode: mode)
            let port = peer.port
            let transport = NIOTransport(group: group, trustRoots: [Array(peer.anchor)])
            let completed = group.next().makePromise(of: Void.self)
            let operation = completed.completeWithTask {
                if mode == "stoptls" {
                    try await transport.connectWithTLS(host: "127.0.0.1", port: port, serverName: "localhost")
                } else {
                    try await transport.connect(host: "127.0.0.1", port: port)
                }
                var iterator = transport.receivedData.makeAsyncIterator()
                var bytes: [UInt8] = []
                while bytes.count < 5, let chunk = await iterator.next() {
                    bytes += chunk
                }
                #expect(String(decoding: bytes, as: UTF8.self) == "ready")
                await transport.stopReceiving()
                #expect(await iterator.next() == nil)
                try await transport.send(Array("after-stop".utf8))
                #expect(await iterator.next() == nil)
            }
            do {
                try await completed.futureResult.get(timeout: .seconds(5))
                try await peer.expectSuccess()
            } catch {
                operation.cancel()
                await transport.disconnect()
                await operation.value
                await peer.stop()
                throw error
            }
            await transport.disconnect()
            await operation.value
            await peer.stop()
        }
    }
}

struct NIODefaultTransportTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_INSTALLED_ROOT"] == "1"),
        arguments: ["starttls", "split", "direct"]
    )
    func `installed root works through the production factory`(mode: String) async throws {
        try await exerciseNIOConnection(mode: mode, useDefault: true)
    }
}

struct NIODefaultUntrustedTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKO_TLS_EXPECT_UNTRUSTED"] == "1"))
    func `production factory rejects the removed root`() async throws {
        try await exerciseNIOConnection(mode: "untrusted", useDefault: true)
    }
}

private func exerciseNIOConnection(mode: String, useDefault: Bool = false) async throws {
    try await withNIOTestGroup { group in
        try await exerciseNIOConnection(mode: mode, useDefault: useDefault, group: group)
    }
}

private func exerciseNIOConnection(mode: String, useDefault: Bool, group: any EventLoopGroup) async throws {
    let peer = try TransportTestPeer(mode: mode == "retry" ? "plaintext" : mode)
    let port = peer.port
    let anchor = peer.anchor
    let transport: any XMPPTransport = useDefault ? makeDefaultXMPPTransport() : NIOTransport(
        handshakeTimeout: .seconds(2), group: group, trustRoots: mode == "untrusted" ? [] : [Array(anchor)]
    )
    #expect(transport is NIOTransport)
    if mode == "retry" {
        let refusedPort = try await closedListenerPort(group: group)
        do {
            try await transport.connect(host: "127.0.0.1", port: refusedPort)
            Issue.record("The deliberately closed listener accepted a connection")
        } catch {}
    }
    let connection = XMPPConnection(transport: transport)
    let reader = EventReader(connection.events)
    do {
        try await exerciseNIOExchange(mode: mode, port: port, connection: connection, reader: reader)
        #expect(!["contaminated", "stalledtls", "untrusted"].contains(mode))
    } catch {
        if !["contaminated", "stalledtls", "untrusted"].contains(mode) {
            await connection.disconnect()
            await peer.stop()
            throw error
        }
        expectNIOFailure(error, mode: mode)
        #expect(await connection.tlsInfo == nil)
    }
    await connection.disconnect()
    do { try await peer.expectSuccess() } catch {
        await peer.stop()
        throw error
    }
    await peer.stop()
}

private func exerciseNIOExchange(mode: String, port: UInt16, connection: XMPPConnection, reader: EventReader, serverName: String = "localhost") async throws {
    let plaintext = mode == "plaintext" || mode == "retry"
    if mode == "direct" {
        try await connection.connectWithTLS(host: "127.0.0.1", port: port, serverName: serverName)
    } else {
        try await connection.connect(host: "127.0.0.1", port: port)
        try await connection.send(XMPPStreamWriter.streamOpening(to: serverName))
        _ = try await reader.awaitFeatures()
        if !plaintext {
            try await connection.send(Array("<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>".utf8))
            let proceed = try await reader.awaitStanza()
            #expect(XMPPConnection.isTLSProceed(proceed))
            try await connection.upgradeTLS(serverName: serverName)
        }
    }
    if !plaintext {
        let info = try #require(await connection.tlsInfo)
        #expect(info.protocolVersion == "TLS 1.2" || info.protocolVersion == "TLS 1.3")
        #expect(info.cipherSuite == nil)
        #expect(info.certificateSHA256 != nil)
        #expect(await connection.channelBindingData != nil)
        try await connection.send(XMPPStreamWriter.streamOpening(to: serverName))
        _ = try await reader.awaitFeatures()
    }
    try await connection.send(Array((plaintext ? "plain-probe" : "secure-probe").utf8))
    let reply = try await reader.awaitStanza()
    #expect(reply.child(named: "body")?.textContent == (plaintext ? "plain-reply" : "secure-reply"))
}

private func expectNIOFailure(_ error: any Error, mode: String) {
    if mode == "stalledtls" {
        if case let XMPPClientError.tlsNegotiationFailed(reason) = error {
            #expect(reason == "The server did not complete the TLS handshake in time")
        } else { Issue.record("Expected handshake timeout, got \(error)") }
    }
    if mode == "untrusted" {
        if case let XMPPClientError.untrustedCertificate(reason) = error {
            #expect(reason == .notTrusted)
        } else { Issue.record("Expected certificate rejection, got \(error)") }
    }
    if mode == "contaminated" {
        if case let XMPPClientError.tlsNegotiationFailed(reason) = error {
            #expect(reason == "The server sent unexpected data after agreeing to start TLS")
        } else { Issue.record("Expected phase rejection, got \(error)") }
    }
}

private func closedListenerPort(group: any EventLoopGroup) async throws -> UInt16 {
    let listener = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
    let port = listener.localAddress?.port
    try await listener.close()
    return try UInt16(#require(port))
}
