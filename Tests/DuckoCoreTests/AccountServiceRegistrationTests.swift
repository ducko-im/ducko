import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Where a registration and the sign-in after it were sent.
private actor Destinations {
    private(set) var registration: (host: String?, port: UInt16)?
    private(set) var signIn: (host: String?, port: Int?)?

    func recordRegistration(host: String?, port: UInt16) {
        registration = (host, port)
    }

    func recordSignIn(host: String?, port: Int?) {
        signIn = (host, port)
    }
}

/// Records where each account signs in, and builds clients for a domain no connect accepts, so the sign-in ends there.
private struct SignInRecorder: XMPPClientFactory {
    let destinations: Destinations

    func makeClient(
        account: Account, password: String, resuming: StreamResumeContext?, requireTLSOverride: Bool?, omemoService: OMEMOService?
    ) async -> (XMPPClient, StreamManagementModule) {
        await destinations.recordSignIn(host: account.host, port: account.port)
        var builder = XMPPClientBuilder(domain: "", username: "", password: password)
        builder.withTransport(MockTransport())
        let sm = StreamManagementModule()
        builder.withModule(sm)
        return await (builder.build(), sm)
    }
}

@MainActor
struct AccountServiceRegistrationTests {
    private let transport = MockTransport()
    private let destinations = Destinations()
    private let service: AccountService

    init() {
        self.service = AccountService(store: MockPersistenceStore(), credentialStore: MockCredentialStore(), clientFactory: SignInRecorder(destinations: destinations))
        service.openRegistrationSession = { [transport, destinations] domain, host, port in
            await destinations.recordRegistration(host: host, port: port)
            return try await RegistrationSession.open(domain: domain, host: host ?? domain, port: port, transport: transport)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `A registration whose form cannot be fetched closes its connection`() async throws {
        let service = service
        let registration = Task { @MainActor in
            try await service.registerAccount(domain: "example.com", username: "juliet", password: "secret")
        }
        try await negotiateStream()
        let get = try await formRequest()
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
        try await negotiateStream()
        let get = try await formRequest()
        await transport.simulateReceive(
            "<iq type='result' id='\(get.id)'><query xmlns='\(XMPPNamespaces.register)'><username/><password/></query></iq>"
        )
        let submission = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) && $0.contains("type=\"set\"") })
        try await transport.simulateReceive("<iq type='result' id='\(#require(extractIQID(from: submission)))'/>")
        // The sign-in fails at its connect, which every recorded client does.
        _ = await registration.result

        let registered = try #require(await destinations.registration)
        #expect(registered.host == host && registered.port == port)
        let signedIn = try #require(await destinations.signIn)
        #expect(signedIn.host == host && signedIn.port == accountPort)
    }

    private func negotiateStream() async throws {
        await transport.waitForSent(count: 1) // stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive("<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>")
        await transport.waitForSent(count: 2) // starttls element
        await transport.simulateReceive("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        await transport.waitForSent(count: 3) // post-TLS stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesNoTLS)
    }

    private func formRequest() async throws -> (id: String, stanza: String) {
        let get = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) && $0.contains("type=\"get\"") })
        return try (#require(extractIQID(from: get)), get)
    }
}
