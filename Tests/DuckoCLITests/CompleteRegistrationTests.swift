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
            form: RegistrationFormInfo(from: form), session: session, typedUsername: "juliet", typedPassword: "secret",
            rejection: nil
        ) { _, error in
            throw error
        } finish: { _, _ in
            Issue.record("A redirected registration signed in")
            return UUID()
        }

        await #expect(throws: CLIError.self) { try await completeRegistration(pending, formatter: PlainFormatter()) }

        #expect(await server.isConnected == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A registration whose automatic submission was refused gets two more submissions`() async throws {
        let form = await RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm, instructions: nil, isRegistered: false,
            dataForm: DataForm(fields: [
                DataFormField(variable: "challenge", type: "hidden", values: ["123"]),
                DataFormField(variable: "from", type: "hidden", values: ["example.com"]),
                DataFormField(variable: "SHA-256", type: "text-single", label: "a1", isRequired: true)
            ])
        )).answeringProofOfWork(prefixFallback: "example.com", allowsSkippingImage: true)
        let reopenings = Counter()

        @MainActor func refusedRegistration(rejection: any Error) async throws -> PendingRegistration {
            let session = try await RegistrationSession.open(
                domain: "example.com", host: "example.com", port: 5222, transport: RegistrationStreamServer(refusesRegistration: true)
            )
            return PendingRegistration(
                form: form, session: session, typedUsername: "juliet", typedPassword: "secret", rejection: rejection
            ) { _, error in
                await reopenings.increment()
                return try await refusedRegistration(rejection: error)
            } finish: { _, _ in
                Issue.record("A refused registration signed in")
                return UUID()
            }
        }

        let pending = try await refusedRegistration(rejection: XMPPRegistrationClient.RegistrationClientError.registrationFailed("Wrong answer"))

        let error = await #expect(throws: (any Error).self) { try await completeRegistration(pending, formatter: PlainFormatter()) }
        #expect(error.map(AccountService.isRegistrationRejected) == true)
        #expect(await reopenings.value == 1)
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A server's side of a registration stream: it offers STARTTLS, proceeds, answers the stream's close, and, when told
/// to, refuses a submitted registration.
private actor RegistrationStreamServer: XMPPTransport {
    nonisolated let receivedData: AsyncStream<[UInt8]>
    private var received: AsyncStream<[UInt8]>.Continuation
    private var openings = 0
    private(set) var isConnected = false
    /// Whether the server answers a submitted registration with an error.
    private let refusesRegistration: Bool

    init(refusesRegistration: Bool = false) {
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.receivedData = stream
        self.received = continuation
        self.refusesRegistration = refusesRegistration
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
        } else if refusesRegistration, sent.contains("type=\"set\""), let id = sent.firstMatch(of: /id="([^"]+)"/)?.1 {
            reply("<iq type='error' id='\(id)'><error type='modify'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")
        }
    }

    func disconnect() {
        isConnected = false
        received.finish()
    }

    var tlsInfo: TLSInfo? {
        nil
    }

    func channelBindings() -> [ChannelBindingType: [UInt8]] {
        [:]
    }

    private func reply(_ text: String) {
        received.yield(Array(text.utf8))
    }
}
