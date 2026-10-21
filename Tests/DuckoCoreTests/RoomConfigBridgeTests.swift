import DuckoXMPP
import Testing
@testable import DuckoCore

struct RoomConfigBridgeTests {
    @Test
    func `Fields without var are keyed by their position in the form`() {
        let form = RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: false,
            dataForm: DataForm(fields: [
                DataFormField(variable: nil, type: "fixed", values: ["Account"]),
                DataFormField(variable: "username", type: "text-single"),
                DataFormField(variable: nil, type: "fixed", values: ["Profile"])
            ])
        )

        let fields = RegistrationFormInfo(from: form).dataForm.fields

        #expect(fields.map(\.id) == [.position(0), .variable("username"), .position(2)])
        #expect(fields.map { $0.toDataFormField().variable } == [nil, "username", nil])
    }
}

struct DataFormInfoTests {
    @Test
    func `A registration form carries the data form's title and instructions`() {
        let form = RegistrationModule.RegistrationForm(
            formType: .dataForm,
            instructions: nil,
            isRegistered: false,
            dataForm: DataForm(title: "Sign up", instructions: ["Pick a name.", "Then a password."])
        )

        let dataForm = RegistrationFormInfo(from: form).dataForm

        #expect(dataForm.title == "Sign up")
        #expect(dataForm.instructions == ["Pick a name.", "Then a password."])
    }

    @Test
    func `A required field without a value holds the form back until it gets one`() {
        var form = DataFormInfo(fields: [
            RoomConfigField(variable: nil, type: "fixed", isRequired: true),
            RoomConfigField(variable: "name", type: "text-single", isRequired: true, values: [" "]),
            RoomConfigField(variable: "note", type: "text-single")
        ])
        #expect(!form.hasRequiredValues)

        form.fields[1].values = ["Lobby"]

        #expect(form.hasRequiredValues)
    }

    @Test
    func `Selecting list-multi options keeps them in the order the form lists them`() {
        var field = RoomConfigField(
            variable: "presencebroadcast",
            type: "list-multi",
            options: [(label: nil, value: "moderator"), (label: nil, value: "participant"), (label: nil, value: "visitor")]
        )

        field.setOption("visitor", isSelected: true)
        field.setOption("moderator", isSelected: true)
        field.setOption("participant", isSelected: true)
        field.setOption("participant", isSelected: false)

        #expect(field.values == ["moderator", "visitor"])
    }

    @Test
    func `A jid-multi field submits no blank lines`() {
        let field = RoomConfigField(variable: "admins", type: "jid-multi", values: ["alice@example.com", "", "bob@example.com", ""])

        #expect(field.toDataFormField().values == ["alice@example.com", "bob@example.com"])
    }
}
