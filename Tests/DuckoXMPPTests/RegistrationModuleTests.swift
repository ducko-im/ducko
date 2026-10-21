import Testing
@testable import DuckoXMPP

struct RegistrationModuleTests {
    @Test
    func `Namespace constants`() {
        #expect(XMPPNamespaces.register == "jabber:iq:register")
    }

    @Test
    func `Module advertises no feature of its own`() {
        let module = RegistrationModule()
        #expect(module.features.isEmpty)
    }

    @Test
    func `A legacy form keeps every field the server lists, in order, with its values`() throws {
        let query = try stanza("""
        <query xmlns='jabber:iq:register'><instructions>Choose</instructions><username>juliet</username>\
        <nick/><password/><first/><last/><email/><registered/></query>
        """)
        let form = RegistrationModule.parseForm(query)
        #expect(form.formType == .legacy)
        #expect(form.isRegistered)
        #expect(form.legacyFields == [
            RegistrationModule.LegacyField(name: "username", value: "juliet"),
            RegistrationModule.LegacyField(name: "nick"),
            RegistrationModule.LegacyField(name: "password"),
            RegistrationModule.LegacyField(name: "first"),
            RegistrationModule.LegacyField(name: "last"),
            RegistrationModule.LegacyField(name: "email")
        ])
    }

    @Test
    func `A form that sends the user elsewhere reports the page`() throws {
        let query = try stanza("""
        <query xmlns='jabber:iq:register'><instructions>Register on the web</instructions>\
        <x xmlns='jabber:x:oob'><url>https://example.com/register</url></x></query>
        """)
        let form = RegistrationModule.parseForm(query)
        #expect(form.redirectURL == "https://example.com/register")
        #expect(form.legacyFields.isEmpty)
    }

    @Test
    func `A legacy registration sends every field it was asked for with its value`() {
        let query = RegistrationModule.buildRegistrationQuery(.legacy([
            RegistrationModule.LegacyField(name: "username", value: "juliet"),
            RegistrationModule.LegacyField(name: "password", value: "secret"),
            RegistrationModule.LegacyField(name: "nick", value: "jules")
        ]))
        #expect(query.childText(named: "username") == "juliet")
        #expect(query.childText(named: "password") == "secret")
        #expect(query.childText(named: "nick") == "jules")
    }

    @Test
    func `RegistrationForm legacy type`() {
        let form = RegistrationModule.RegistrationForm(
            formType: .legacy,
            instructions: "Please provide a username and password",
            isRegistered: false,
            legacyFields: [RegistrationModule.LegacyField(name: "username"), RegistrationModule.LegacyField(name: "password")]
        )
        #expect(form.formType == .legacy)
        #expect(form.instructions == "Please provide a username and password")
        #expect(!form.isRegistered)
        #expect(form.legacyFields.map(\.name) == ["username", "password"])
        #expect(form.dataForm.fields.isEmpty)
    }

    @Test
    func `RegistrationForm data form type`() {
        let fields = [
            DataFormField(variable: "username", type: "text-single"),
            DataFormField(variable: "password", type: "text-private"),
            DataFormField(variable: "email", type: "text-single")
        ]
        let form = RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: true,
            dataForm: DataForm(fields: fields)
        )
        #expect(form.formType == .dataForm)
        #expect(form.isRegistered)
        #expect(form.dataForm.fields.count == 3)
    }

    @Test
    func `FormType cases`() {
        let legacy = RegistrationModule.FormType.legacy
        let dataForm = RegistrationModule.FormType.dataForm
        switch legacy {
        case .legacy: break
        case .dataForm: Issue.record("Expected legacy")
        }
        switch dataForm {
        case .dataForm: break
        case .legacy: Issue.record("Expected dataForm")
        }
    }
}
