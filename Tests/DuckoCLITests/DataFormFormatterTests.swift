import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

struct DataFormFormatterTests {
    private let form = DataFormInfo(
        title: "Configuration for room",
        instructions: ["Complete this form."],
        fields: [
            RoomConfigField(variable: "FORM_TYPE", type: "hidden", values: ["http://jabber.org/protocol/muc#roomconfig"]),
            RoomConfigField(variable: nil, position: 1, type: "fixed", values: ["Access"]),
            RoomConfigField(
                variable: "muc#roomconfig_roomname",
                type: "text-single",
                label: "Room Name",
                description: "Shown in room lists",
                isRequired: true
            ),
            RoomConfigField(variable: "muc#roomconfig_roomsecret", type: "text-private", label: "Password", values: ["hunter2"])
        ]
    )

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter()])
    func `text output shows the title, instructions, fixed text, descriptions and required markers`(formatter: any CLIFormatter) {
        let output = formatter.formatDataForm(form)

        #expect(output.contains("Configuration for room"))
        #expect(output.contains("Complete this form."))
        #expect(output.contains("Access"))
        #expect(output.contains("Shown in room lists"))
        #expect(output.contains("(required)"))
        #expect(!output.contains("FORM_TYPE"))
    }

    @Test(arguments: [PlainFormatter() as any CLIFormatter, ANSIFormatter(), JSONFormatter()])
    func `a text-private value is obscured`(formatter: any CLIFormatter) {
        let output = formatter.formatDataForm(form)

        #expect(output.contains(obscuredDataFormValue))
        #expect(!output.contains("hunter2"))
    }

    @Test func `plain output marks only the required field`() {
        let lines = PlainFormatter().formatDataForm(form).split(separator: "\n")

        #expect(lines.contains("  Room Name (required): (empty)"))
        #expect(lines.contains("  Password: \(obscuredDataFormValue)"))
    }

    @Test func `JSON keeps each field's raw attributes`() throws {
        let output = JSONFormatter().formatDataForm(form)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let fields = try #require(json["fields"] as? [[String: Any]])

        #expect(json["type"] as? String == "data_form")
        #expect(json["title"] as? String == "Configuration for room")
        #expect(json["instructions"] as? [String] == ["Complete this form."])
        #expect(fields.map { $0["type"] as? String } == ["fixed", "text-single", "text-private"])
        #expect(fields[0]["values"] as? [String] == ["Access"])
        #expect(fields[1]["var"] as? String == "muc#roomconfig_roomname")
        #expect(fields[1]["desc"] as? String == "Shown in room lists")
        #expect(fields[1]["required"] as? String == "true")
        #expect(fields[2]["required"] == nil)
    }
}
