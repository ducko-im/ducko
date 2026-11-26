import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Where a registration and the sign-in after it were sent, and how many registration connections opened.
private actor Destinations {
    private(set) var registration: (host: String?, port: UInt16)?
    private(set) var signIn: (host: String?, port: Int?)?
    private(set) var registrationConnections = 0

    /// Records a registration connection and returns its index.
    func recordRegistration(host: String?, port: UInt16) -> Int {
        registration = (host, port)
        registrationConnections += 1
        return registrationConnections - 1
    }

    func recordSignIn(host: String?, port: Int?) {
        signIn = (host, port)
    }
}

/// Records where each account signs in, and builds clients for a domain no connect accepts, so the sign-in ends there.
private struct SignInRecorder: XMPPClientFactory {
    let destinations: Destinations

    func makeClient(
        account: Account, secret: SignInSecret, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        await destinations.recordSignIn(host: account.host, port: account.port)
        var builder = XMPPClientBuilder(domain: "", username: "", secret: secret)
        builder.withTransport(MockTransport())
        let sm = StreamManagementModule()
        builder.withModule(sm)
        return await (builder.build(), sm)
    }
}

@MainActor
struct AccountServiceRegistrationTests {
    /// One transport per registration connection, in the order they open.
    private let transports = [MockTransport(), MockTransport(), MockTransport()]
    private let destinations = Destinations()
    private let service: AccountService

    private var transport: MockTransport {
        transports[0]
    }

    init() {
        self.service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: SignInRecorder(destinations: destinations))
        service.openRegistrationSession = { [transports, destinations] domain, host, port in
            let index = await destinations.recordRegistration(host: host, port: port)
            return try await RegistrationSession.open(domain: domain, host: host ?? domain, port: port, transport: transports[index])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `A registration whose form cannot be fetched closes its connection`() async throws {
        let service = service
        let registration = Task { @MainActor in
            try await service.registerAccount(domain: "example.com", username: "juliet", password: "secret")
        }
        await negotiateRegistrationStream(on: transport)
        let get = try await registrationFormRequest(on: transport)
        await transport.simulateReceive("<iq type='error' id='\(get.id)'><error type='cancel'><not-allowed xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>")

        await #expect(throws: (any Error).self) { try await registration.value }
        #expect(await transport.isConnected == false)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        (String?.some("xmpp.example.net"), UInt16(5223), Int?.some(5223)),
        (nil, 5222, nil)
    ])
    func `A registration goes to the host given and the new account signs in there`(host: String?, port: UInt16, accountPort: Int?) async throws {
        let service = service
        let registration = Task { @MainActor in
            try await service.registerAccount(domain: "example.com", username: "juliet", password: "secret", host: host, port: port)
        }
        try await completeRegistration(on: transport)
        // The sign-in fails at its connect, which every recorded client does.
        _ = await registration.result

        let registered = try #require(await destinations.registration)
        #expect(registered.host == host && registered.port == port)
        let signedIn = try #require(await destinations.signIn)
        #expect(signedIn.host == host && signedIn.port == accountPort)
    }

    // MARK: - CAPTCHA

    @Test(.timeLimit(.minutes(1)))
    func `A form with an inline image comes back to be completed, showing the image`() async throws {
        let registration = register()
        try await serveForm(CaptchaFormFixtures.query(CaptchaFormFixtures.ocr()), on: transport)

        let pending = try await needsMoreFields(registration.value)

        guard case .inline = pending.form.captcha?.challenges.first?.image else {
            Issue.record("Expected the inline image")
            return
        }
        await pending.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `A solved proof of work registers without showing the form, sending the answer and no image answer`() async throws {
        let registration = register()
        try await serveForm(CaptchaFormFixtures.query(CaptchaFormFixtures.ocr() + CaptchaFormFixtures.proofOfWork(CaptchaFormFixtures.solvableLabel)), on: transport)
        let submission = try await submission(on: transport)
        await transport.simulateReceive("<iq type='result' id='\(submission.id)'/>")
        // The sign-in fails at its connect, which every recorded client does.
        _ = await registration.result

        #expect(submission.stanza.contains("var=\"SHA-256\""))
        #expect(!submission.stanza.contains("var=\"ocr\""))
        #expect(await destinations.signIn != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A form whose proof of work can't be solved comes back without anything submitted`() async throws {
        let registration = register()
        try await serveForm(CaptchaFormFixtures.query(CaptchaFormFixtures.proofOfWork(CaptchaFormFixtures.tooHardLabel)), on: transport)

        let pending = try await needsMoreFields(registration.value)

        #expect(pending.form.captcha?.isUnanswerable == true)
        let submitted = await transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains("type=\"set\"") }
        #expect(!submitted)
        await pending.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `A rejected automatic submission comes back on a fresh form, with the rejection and the typed values`() async throws {
        let registration = register()
        try await serveForm("<query xmlns='\(XMPPNamespaces.register)'><username/><password/></query>", on: transports[0])
        try await reject(submission(on: transports[0]).id, on: transports[0])
        try await serveForm("<query xmlns='\(XMPPNamespaces.register)'><username/><password/><nick/></query>", on: transports[1])

        let pending = try await needsMoreFields(registration.value)

        #expect(try AccountService.isRegistrationRejected(#require(pending.rejection)))
        #expect(pending.form.value(of: "username") == "juliet")
        #expect(pending.form.value(of: "password") == "secret")
        #expect(await transports[0].isConnected == false)
        #expect(await destinations.registrationConnections == 2)
        await pending.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `After a rejected proof of work every fresh form asks for the image, with its own challenge and the answer cleared`() async throws {
        func captcha(_ challengeID: String) -> String {
            CaptchaFormFixtures.query(CaptchaFormFixtures.ocr() + CaptchaFormFixtures.proofOfWork(CaptchaFormFixtures.solvableLabel), challengeID: challengeID)
        }
        let registration = register()
        try await serveForm(captcha("1"), on: transports[0])
        try await reject(submission(on: transports[0]).id, on: transports[0])
        try await serveForm(captcha("2"), on: transports[1])
        let second = try await needsMoreFields(registration.value)
        #expect(second.form.captcha?.challenges.map(\.variable) == ["ocr"])

        var answered = second.form
        let ocr = try #require(answered.dataForm.fields.firstIndex { $0.variable == "ocr" })
        answered.dataForm.fields[ocr].values = ["wrong"]
        let submitting = Task { @MainActor in try await second.submit(answered) }
        try await reject(submission(on: transports[1]).id, on: transports[1])
        let error = try await #require(throws: (any Error).self) { try await submitting.value }
        #expect(AccountService.isRegistrationRejected(error))
        let reopening = Task { @MainActor in try await second.reopen(after: answered, error: error) }
        try await serveForm(captcha("3"), on: transports[2])
        let third = try await reopening.value

        #expect(third.form.captcha?.challenges.map(\.variable) == ["ocr"])
        #expect(third.form.value(of: "challenge") == "3")
        #expect(third.form.dataForm.fields.first { $0.variable == "ocr" }?.values.allSatisfy(\.isEmpty) == true)
        #expect(third.form.value(of: "username") == "juliet")
        #expect(await destinations.registrationConnections == 3)
        await third.cancel()
    }

    @Test(.timeLimit(.minutes(1)))
    func `A sign-in failure after the server accepted the registration opens no fresh form`() async throws {
        let registration = register()
        try await completeRegistration(on: transport)

        await #expect(throws: (any Error).self) { try await registration.value }
        #expect(await destinations.registrationConnections == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Checking a server's registration form answers its proof of work and closes the connection`() async throws {
        let service = service
        let checking = Task { @MainActor in try await service.retrieveRegistrationForm(domain: "example.com") }
        try await serveForm(CaptchaFormFixtures.query(CaptchaFormFixtures.proofOfWork(CaptchaFormFixtures.solvableLabel)), on: transport)

        let form = try await checking.value

        #expect(form.captcha?.proofOfWork?.answer != nil)
        #expect(await transport.isConnected == false)
    }

    @Test
    func `Only a refusal from the server counts as a rejected registration`() {
        #expect(AccountService.isRegistrationRejected(XMPPRegistrationClient.RegistrationClientError.registrationFailed("Taken")))
        #expect(AccountService.isRegistrationRejected(XMPPStanzaError(errorType: .modify, condition: .notAcceptable)))
        #expect(!AccountService.isRegistrationRejected(XMPPRegistrationClient.RegistrationClientError.connectionClosed))
    }

    @Test
    func `Only a registration connection that closed counts as closed`() {
        #expect(AccountService.isRegistrationConnectionClosed(XMPPRegistrationClient.RegistrationClientError.connectionClosed))
        #expect(!AccountService.isRegistrationConnectionClosed(XMPPRegistrationClient.RegistrationClientError.registrationFailed("Taken")))
        #expect(!AccountService.isRegistrationConnectionClosed(XMPPStanzaError(errorType: .modify, condition: .notAcceptable)))
    }

    private func register() -> Task<RegistrationOutcome, any Error> {
        let service = service
        return Task { @MainActor in
            try await service.registerAccount(domain: "example.com", username: "juliet", password: "secret")
        }
    }

    private func needsMoreFields(_ outcome: RegistrationOutcome) throws -> PendingRegistration {
        guard case let .needsMoreFields(pending) = outcome else { throw CancellationError() }
        return pending
    }

    /// Negotiates the registration stream on `transport` and answers its form request with `query`.
    private func serveForm(_ query: String, on transport: MockTransport) async throws {
        await negotiateRegistrationStream(on: transport)
        let get = try await registrationFormRequest(on: transport)
        await transport.simulateReceive("<iq type='result' id='\(get.id)'>\(query)</iq>")
    }

    /// The registration `transport` sent, and its id.
    private func submission(on transport: MockTransport) async throws -> (id: String, stanza: String) {
        let set = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) && $0.contains("type=\"set\"") })
        return try (#require(extractIQID(from: set)), set)
    }

    private func reject(_ id: String, on transport: MockTransport) async {
        await transport.simulateReceive(
            "<iq type='error' id='\(id)'><error type='modify'><not-acceptable xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/></error></iq>"
        )
    }
}
