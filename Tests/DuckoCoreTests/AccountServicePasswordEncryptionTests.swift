import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// A password goes to the server only over an encrypted stream.
@MainActor
struct AccountServicePasswordEncryptionTests {
    private let transport = MockTransport()
    private let service: AccountService

    init() {
        self.service = AccountService(
            store: MockPersistenceStore(), credentialStore: MockCredentialStore(),
            clientFactory: MockXMPPClientFactory(transport: transport, modules: [RegistrationModule()])
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func `Changing the password over a plaintext stream fails before anything is sent`() async throws {
        let id = try await connectPlaintext()

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            try await service.changePassword(accountID: id, newPassword: "new-secret")
        }
        #expect(error.map(isUnencryptedConnection) == true)
        #expect(await !sentRegistration())
        await service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Changing the password over an encrypted stream sends it`() async throws {
        let id = try await connectEncrypted()

        let changing = Task { @MainActor [service] in try await service.changePassword(accountID: id, newPassword: "new-secret") }
        let request = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) })
        try await transport.simulateReceive("<iq type='result' id='\(#require(extractIQID(from: request)))'/>")

        try await changing.value
        await service.disconnect(accountID: id)
    }

    /// How a registration form can carry a password.
    enum PasswordField: String, CaseIterable, CustomTestStringConvertible {
        case legacyPassword = "a legacy password element"
        case privatePassword = "a text-private password field"
        case plainPassword = "a password field that isn't text-private"
        case privateField = "a text-private field with another name"

        var testDescription: String {
            rawValue
        }

        var form: RegistrationFormInfo {
            switch self {
            case .legacyPassword:
                var form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
                    formType: .legacy, instructions: nil, isRegistered: true,
                    legacyFields: [RegistrationModule.LegacyField(name: "username"), RegistrationModule.LegacyField(name: "password")]
                ))
                form.legacyFields[0].value = "alice"
                form.legacyFields[1].value = "secret"
                return form
            case .privatePassword: return dataForm(password: DataFormField(variable: "password", type: "text-private", values: ["secret"]))
            case .plainPassword: return dataForm(password: DataFormField(variable: "password", type: "text-single", values: ["secret"]))
            case .privateField: return dataForm(password: DataFormField(variable: "pass", type: "text-private", values: ["secret"]))
            }
        }

        private func dataForm(password: DataFormField) -> RegistrationFormInfo {
            RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
                formType: .dataForm, instructions: nil, isRegistered: true,
                dataForm: DataForm(fields: [DataFormField(variable: "username", type: "text-single", values: ["alice"]), password])
            ))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: PasswordField.allCases)
    func `A registration carrying a password is refused over a plaintext stream, before anything is sent`(field: PasswordField) async throws {
        let id = try await connectPlaintext()

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            try await service.submitRegistration(accountID: id, form: field.form)
        }
        #expect(error.map(isUnencryptedConnection) == true)
        #expect(await !sentRegistration())
        await service.disconnect(accountID: id)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [true, false])
    func `A registration goes out over an encrypted stream, and one without a password over any stream`(encrypted: Bool) async throws {
        let id = try await encrypted ? connectEncrypted() : connectPlaintext()
        let form = registrationForm(password: encrypted ? "secret" : "")

        let submitting = Task { @MainActor [service] in try await service.submitRegistration(accountID: id, form: form) }
        let request = try #require(await transport.waitForSent { $0.contains(XMPPNamespaces.register) })
        try await transport.simulateReceive("<iq type='result' id='\(#require(extractIQID(from: request)))'/>")

        try await submitting.value
        await service.disconnect(accountID: id)
    }

    @Test
    func `A disconnected account is reported as not connected`() async throws {
        let id = try await service.createAccount(jidString: "alice@example.com")

        let error = await #expect(throws: AccountService.AccountServiceError.self) {
            try await service.changePassword(accountID: id, newPassword: "new-secret")
        }
        guard case .notConnected = error else {
            Issue.record("Expected notConnected, got \(String(describing: error))")
            return
        }
    }

    private func isUnencryptedConnection(_ error: AccountService.AccountServiceError) -> Bool {
        guard case .unencryptedConnection = error else { return false }
        return true
    }

    private func connectPlaintext() async throws -> UUID {
        let id = try await service.createAccount(jidString: "alice@example.com", requireTLS: false)
        _ = try await driveMockConnect(service, accountID: id, transport: transport)
        #expect(service.tlsInfo(for: id) == nil)
        await transport.clearSentBytes()
        return id
    }

    private func connectEncrypted() async throws -> UUID {
        await transport.setTLSInfo(TLSInfo(protocolVersion: "TLS 1.3", wireVersion: 0x0304, cipherSuite: nil))
        let id = try await service.createAccount(jidString: "alice@example.com")
        let connecting = Task { @MainActor [service] in try await service.connect(accountID: id, password: "secret") }
        try await exchange(
            transport, matching: "<stream:stream",
            response: testServerStreamOpen + "<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>"
        )
        try await exchange(transport, matching: "<starttls", response: "<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        try await exchange(transport, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesNoTLS)
        try await exchange(transport, matching: "<auth", response: "<success xmlns='urn:ietf:params:xml:ns:xmpp-sasl'/>")
        try await exchange(transport, matching: "<stream:stream", response: testServerStreamOpen + testFeaturesBind)
        try await exchange(transport, matching: "<bind", response: testBindResult)
        try await connecting.value
        try #require(service.tlsInfo(for: id) != nil)
        await transport.clearSentBytes()
        return id
    }

    /// A signed-in registration data form whose password field holds `password`.
    private func registrationForm(password: String) -> RegistrationFormInfo {
        var form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm, instructions: nil, isRegistered: true,
            dataForm: DataForm(fields: [
                DataFormField(variable: "username", type: "text-single", values: ["alice"]),
                DataFormField(variable: "password", type: "text-private"),
                DataFormField(variable: "nick", type: "text-single", values: ["Alice"])
            ])
        ))
        form.dataForm.fields[1].values = password.isEmpty ? [] : [password]
        return form
    }

    private func sentRegistration() async -> Bool {
        await transport.sentBytes.contains { String(decoding: $0, as: UTF8.self).contains(XMPPNamespaces.register) }
    }
}
