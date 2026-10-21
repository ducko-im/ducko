import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

struct RegistrationFormInfoTests {
    @Test(arguments: [
        (legacyForm(["username", "password", "email"]), "juliet@example.net", true),
        (legacyForm(["username", "password", "email"]), nil, false),
        (legacyForm(["username", "password", "nick"]), "juliet@example.net", false),
        (legacyForm(["username", "password"], redirectURL: "https://example.com/register"), nil, false),
        (dataForm(["username", "password"]), nil, true),
        (dataForm(["username", "password", "ocr"]), nil, false),
        (dataForm(["username", "password", "email"]), nil, false),
        (dataForm(["username", "password"], optional: ["email"]), nil, false),
        (dataForm(["username", "password"], optional: ["email"]), "juliet@example.net", true)
    ])
    func `Only a form asking for nothing beyond the typed account details is submitted unseen`(
        form: RegistrationModule.RegistrationForm, email: String?, submitsUnseen: Bool
    ) {
        let filled = RegistrationFormInfo(from: form).filling(username: "juliet", password: "secret", email: email)
        #expect(filled.asksOnlyForAccountDetails == submitsUnseen)
    }

    @Test
    func `A legacy form needs a value for every element it asks for`() {
        var form = RegistrationFormInfo(from: legacyForm(["username", "password", "nick"]))
            .filling(username: "juliet", password: "secret", email: nil)
        #expect(!form.hasRequiredValues)

        form.legacyFields[2].value = "jules"

        #expect(form.hasRequiredValues)
    }

    @Test
    func `A field holding only spaces has no value, in a legacy form as in a data form`() {
        var legacy = RegistrationFormInfo(from: legacyForm(["username", "password", "nick"]))
            .filling(username: "juliet", password: "secret", email: nil)
        legacy.legacyFields[2].value = "  "
        var data = RegistrationFormInfo(from: dataForm(["username", "password", "nick"]))
            .filling(username: "juliet", password: "secret", email: nil)
        data.dataForm.fields[3].values = ["  "]

        #expect(!legacy.canSubmit)
        #expect(!data.canSubmit)
    }

    @Test
    func `A form with nothing to fill in cannot be submitted`() {
        let form = RegistrationFormInfo(from: legacyForm([], redirectURL: "https://example.com/register"))

        #expect(form.hasRequiredValues)
        #expect(!form.canSubmit)
    }

    @Test
    func `A required boolean without a value counts as false and is submitted so`() {
        let form = RegistrationFormInfo(from: RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: false,
            dataForm: DataForm(fields: [DataFormField(variable: "terms", type: "boolean", isRequired: true)])
        ))

        #expect(form.canSubmit)
        guard case let .dataForm(fields) = form.submission else {
            Issue.record("Expected a data form submission")
            return
        }
        #expect(fields.map(\.values) == [["0"]])
    }

    @Test(arguments: [
        ("https://example.com/register", true),
        ("http://example.com/register", true),
        ("javascript:alert(1)", false),
        ("file:///etc/passwd", false),
        ("xmpp:admin@example.com", false)
    ])
    func `Only a web address becomes the redirect link`(redirect: String, isLink: Bool) {
        let form = RegistrationFormInfo(from: legacyForm([], redirectURL: redirect))

        #expect(form.redirectURL?.absoluteString == redirect)
        #expect(form.redirectLink == (isLink ? form.redirectURL : nil))
    }
}

struct PendingRegistrationTests {
    @Test(.timeLimit(.minutes(1)))
    func `Cancelling a pending registration closes its connection`() async throws {
        let transport = MockTransport()
        let session = try await openSession(on: transport)
        let pending = PendingRegistration(
            form: RegistrationFormInfo(from: legacyForm(["username", "password", "nick"])),
            session: session, typedUsername: "juliet", typedPassword: "secret"
        ) { _, _ in UUID() }

        await pending.cancel()

        #expect(await transport.isConnected == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Submitting sends every field the server asked for and signs in with the form's username`() async throws {
        let transport = MockTransport()
        let session = try await openSession(on: transport)
        let signedIn = Credentials()
        var form = RegistrationFormInfo(from: legacyForm(["username", "password", "nick"]))
            .filling(username: "juliet", password: "secret", email: nil)
        form.legacyFields[0].value = "romeo"
        form.legacyFields[2].value = "jules"
        let pending = PendingRegistration(
            form: form, session: session, typedUsername: "juliet", typedPassword: "secret"
        ) { username, password in
            await signedIn.record(username, password)
            return UUID()
        }

        let submitting = Task { try await pending.submit(form) }
        let request = try #require(await transport.waitForSent { $0.contains("jabber:iq:register") && $0.contains("type=\"set\"") })
        let reply = try stanza(request)
        let query = try #require(reply.child(named: "query", namespace: XMPPNamespaces.register))
        #expect(query.childText(named: "username") == "romeo")
        #expect(query.childText(named: "password") == "secret")
        #expect(query.childText(named: "nick") == "jules")
        await transport.simulateReceive("<iq type='result' id='\(reply.attribute("id") ?? "")'/>")
        _ = try await submitting.value

        #expect(await signedIn.values == ["romeo", "secret"])
        #expect(await transport.isConnected == false)
    }

    private func openSession(on transport: MockTransport) async throws -> RegistrationSession {
        let opening = Task {
            try await RegistrationSession.open(domain: "example.com", host: "example.com", port: 5222, transport: transport)
        }
        await transport.waitForSent(count: 1) // stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive("<stream:features><starttls xmlns='urn:ietf:params:xml:ns:xmpp-tls'/></stream:features>")
        await transport.waitForSent(count: 2) // starttls element
        await transport.simulateReceive("<proceed xmlns='urn:ietf:params:xml:ns:xmpp-tls'/>")
        await transport.waitForSent(count: 3) // post-TLS stream opening
        await transport.simulateReceive(testServerStreamOpen)
        await transport.simulateReceive(testFeaturesNoTLS)
        return try await opening.value
    }

    private func stanza(_ xml: String) throws -> DuckoXMPP.XMLElement {
        let events = XMPPStreamParser().parse(Array((testServerStreamOpen + xml).utf8))
        for case let .stanzaReceived(element) in events {
            return element
        }
        throw XMPPClientError.unexpectedStreamState("No stanza in \(xml)")
    }
}

private actor Credentials {
    private(set) var values: [String] = []

    func record(_ username: String, _ password: String) {
        values = [username, password]
    }
}

private func legacyForm(_ names: [String], redirectURL: String? = nil) -> RegistrationModule.RegistrationForm {
    RegistrationModule.RegistrationForm(
        formType: .legacy,
        instructions: nil,
        isRegistered: false,
        legacyFields: names.map { RegistrationModule.LegacyField(name: $0) },
        redirectURL: redirectURL
    )
}

/// A registration data form whose `required` fields are marked required and whose `optional` ones are not.
private func dataForm(_ required: [String], optional: [String] = []) -> RegistrationModule.RegistrationForm {
    func field(_ variable: String, isRequired: Bool) -> DataFormField {
        DataFormField(variable: variable, type: variable == "password" ? "text-private" : "text-single", isRequired: isRequired)
    }
    return RegistrationModule.RegistrationForm(
        formType: .dataForm,
        instructions: nil,
        isRegistered: false,
        dataForm: DataForm(fields: [DataFormField(variable: "FORM_TYPE", type: "hidden", values: [XMPPNamespaces.register])]
            + required.map { field($0, isRequired: true) } + optional.map { field($0, isRequired: false) })
    )
}
