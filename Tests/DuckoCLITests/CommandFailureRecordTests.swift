import ArgumentParser
import Foundation
import Testing
@testable import DuckoCLI

struct CommandFailureRecordTests {
    @Test(arguments: [
        ["send", "not a jid@@", "hi", "--output", "json"],
        ["room", "list", "--output", "json"]
    ])
    func `a JSON command that fails gets one error record`(arguments: [String]) throws {
        let command = try DuckoCLI.parseAsRoot(arguments)
        let record = try #require(commandFailureRecord(for: CLIError.invalidJID("not a jid@@"), command: command))
        expectSnakeCaseKeys(record)
        let json = try JSONDecoder().decode([String: String].self, from: Data(record.utf8))
        #expect(json == ["type": "error", "message": CLIError.invalidJID("not a jid@@").localizedDescription])
    }

    /// The record finds a command's output format by reflection, so every command that takes `--output` must hold
    /// its global options where reflection sees them.
    @Test func `every command that takes --output holds the global options the record reads`() {
        var checked: Set<ObjectIdentifier> = []
        var missing: [String] = []
        func visit(_ command: any ParsableCommand.Type) {
            guard command.configuration.subcommands.isEmpty else {
                command.configuration.subcommands.forEach(visit)
                return
            }
            guard command.helpMessage().contains("--output") else { return }
            checked.insert(ObjectIdentifier(command))
            if globalOptionGroup(of: command.init()) == nil {
                missing.append(String(reflecting: command))
            }
        }
        visit(DuckoCLI.self)
        // A top-level command, and the first and last commands of a group, so a walk that skips a level or the rest of
        // a group shows.
        #expect(checked.contains(ObjectIdentifier(DuckoCLI.Send.self)))
        #expect(checked.contains(ObjectIdentifier(DuckoCLI.Room.ListRooms.self)))
        #expect(checked.contains(ObjectIdentifier(DuckoCLI.Room.Send.self)))
        #expect(missing.isEmpty, Comment(rawValue: missing.joined(separator: ", ")))
    }

    @Test(arguments: [ExitCode.failure, ExitCode(3)])
    func `an exit status gets no record, since the command printed its own`(code: ExitCode) throws {
        let command = try DuckoCLI.parseAsRoot(["roster", "add", "bob@example.com", "--output", "json"])
        #expect(commandFailureRecord(for: code, command: command) == nil)
    }

    @Test(arguments: [
        ["send", "bob@example.com", "hi", "--output", "plain"],
        ["send", "bob@example.com", "hi", "--output", "ansi"],
        ["logs", "path"]
    ])
    func `a command that does not print JSON gets no record`(arguments: [String]) throws {
        let command = try DuckoCLI.parseAsRoot(arguments)
        #expect(commandFailureRecord(for: CLIError.noPassword, command: command) == nil)
    }
}
