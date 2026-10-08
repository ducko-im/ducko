import ArgumentParser
import Testing
@testable import DuckoCLI

struct HistoryCommandParsingTests {
    @Test func `parse with a JID alone`() throws {
        let command = try DuckoCLI.History.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
        #expect(command.search == nil)
    }

    @Test func `parse with a JID and a keyword`() throws {
        let command = try DuckoCLI.History.parse(["alice@example.com", "--search", "needle"])
        #expect(command.jid == "alice@example.com")
        #expect(command.search == "needle")
    }

    @Test func `a keyword without a JID searches all conversations`() throws {
        let command = try DuckoCLI.History.parse(["--search", "needle", "--limit", "5"])
        #expect(command.jid == nil)
        #expect(command.search == "needle")
        #expect(command.limit == 5)
    }

    @Test(arguments: [[], ["--limit", "5"]])
    func `everything but a keyword search needs a JID`(arguments: [String]) {
        expectParseError(DuckoCLI.History.self, arguments, containing: "Only --search works without one")
    }

    @Test(arguments: [["--search", "needle", "--server"], ["--search", "needle", "--before", "2026-03-01T00:00:00Z"]])
    func `a search of all conversations takes neither a date nor the server`(arguments: [String]) {
        expectParseError(DuckoCLI.History.self, arguments, containing: "need a JID")
    }
}
