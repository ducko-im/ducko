import Foundation
import Testing
@testable import DuckoCLI
@testable import DuckoCore
@testable import DuckoXMPP

@MainActor
struct CompleteRegistrationTests {
    @Test(.timeLimit(.minutes(1)))
    func `A form that only names a web page closes the registration's connection`() async throws {
        let server = RegistrationStreamServer()
        let session = try await RegistrationSession.open(domain: "example.com", host: "example.com", port: 5222, transport: server)
        let form = RegistrationModule.RegistrationForm(
            formType: .legacy, instructions: nil, isRegistered: false, legacyFields: [], redirectURL: "https://example.com/register"
        )
        let pending = PendingRegistration(
            form: RegistrationFormInfo(from: form), session: session, typedUsername: "juliet", typedPassword: "secret"
        ) { _, _ in
            Issue.record("A redirected registration signed in")
            return UUID()
        }

        await #expect(throws: CLIError.self) { try await completeRegistration(pending, formatter: PlainFormatter()) }

        #expect(await server.isConnected == false)
    }
}

/// A server's side of a registration stream: it offers STARTTLS, proceeds, and answers the stream's close.
private actor RegistrationStreamServer: XMPPTransport {
    nonisolated let receivedData: AsyncStream<[UInt8]>
    private var received: AsyncStream<[UInt8]>.Continuation
    private var openings = 0
    private(set) var isConnected = false

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.received = continuation
    }

    func connect(host _: String, port _: UInt16) {
        isConnected = true
    }

    func connectWithTLS(host _: String, port _: UInt16, serverName _: String) {
        isConnected = true
    }

    func stopReceiving() {
        received.finish()
    }

    func upgradeTLS(serverName _: String) -> AsyncStream<[UInt8]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        received = continuation
        return stream
    }

    func send(_ bytes: [UInt8]) {
        let sent = String(decoding: bytes, as: UTF8.self)
        if sent.contains("<stream:stream") {
            openings += 1
            let features = openings == 1 ? "<starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>" : ""
            reply("<stream:stream xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams' from='example.com' version='1.0'>"
                + "<stream:features>\(features)</stream:features>")
        } else if sent.contains("<starttls") {
            reply("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        } else if sent.hasPrefix("</stream:stream>") {
            reply("</stream:stream>")
        }
    }

    func disconnect() {
        isConnected = false
        received.finish()
    }

    private func reply(_ text: String) {
        received.yield(Array(text.utf8))
    }
}
