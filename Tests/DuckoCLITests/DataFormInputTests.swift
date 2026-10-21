import DuckoCore
import Testing
@testable import DuckoCLI

struct DataFormInputTests {
    private let options: [(label: String?, value: String)] = [
        (label: "Moderators", value: "moderator"),
        (label: "Participants", value: "participant"),
        (label: "Visitors", value: "visitor")
    ]

    @Test(arguments: ["list-single", "list-multi"])
    func `a list field rejects a value it does not list`(type: String) {
        let field = RoomConfigField(variable: "whois", type: type, options: options)

        #expect(throws: CLIError.self) {
            try dataFormValues(typed: ["anyone"], for: field)
        }
    }

    @Test func `a list field takes an option by its value or its label`() throws {
        let field = RoomConfigField(variable: "whois", type: "list-single", options: options)

        #expect(try dataFormValues(typed: ["moderator"], for: field) == ["moderator"])
        #expect(try dataFormValues(typed: ["Visitors"], for: field) == ["visitor"])
    }

    @Test func `a list-multi field keeps the options in the order the form lists them`() throws {
        let field = RoomConfigField(variable: "presencebroadcast", type: "list-multi", options: options)

        #expect(try dataFormValues(typed: ["visitor, Moderators"], for: field) == ["moderator", "visitor"])
    }

    @Test func `a text-multi line containing a comma stays one value`() throws {
        let field = RoomConfigField(variable: "description", type: "text-multi")

        #expect(try dataFormValues(typed: ["Hello, world", "Second line"], for: field) == ["Hello, world", "Second line"])
    }

    @Test func `a jid-multi field splits on commas and lines`() throws {
        let field = RoomConfigField(variable: "admins", type: "jid-multi")

        let values = try dataFormValues(typed: ["alice@example.com, bob@example.com", "carol@example.com"], for: field)

        #expect(values == ["alice@example.com", "bob@example.com", "carol@example.com"])
    }

    @Test func `typing nothing keeps the current values`() throws {
        let field = RoomConfigField(variable: "name", type: "text-single", values: ["Lobby"])

        #expect(try dataFormValues(typed: [" "], for: field) == nil)
    }

    @Test(arguments: [([" secret "], [" secret "]), ([" "], [" "]), ([""], nil)] as [([String], [String]?)])
    func `a hidden value is taken as typed, and only an empty line keeps the current one`(typed: [String], expected: [String]?) throws {
        let field = RoomConfigField(variable: "password", type: "text-private", values: ["old"])

        #expect(try dataFormValues(typed: typed, for: field) == expected)
    }

    @Test(arguments: [("yes", "1"), ("On", "1"), ("true", "1"), ("1", "1"), ("no", "0"), ("OFF", "0"), ("false", "0"), ("0", "0")])
    func `a boolean field takes a yes or no answer as 1 or 0`(typed: String, expected: String) throws {
        let field = RoomConfigField(variable: "public", type: "boolean")

        #expect(try dataFormValues(typed: [typed], for: field) == [expected])
    }

    @Test func `a boolean field rejects an answer that is not yes or no`() {
        let field = RoomConfigField(variable: "public", type: "boolean")

        #expect(throws: CLIError.self) {
            try dataFormValues(typed: ["maybe"], for: field)
        }
    }
}
