import ArgumentParser
import Testing
@testable import DuckoCLI

struct PresenceCommandParsingTests {
    @Test func `parse --for with status`() throws {
        let command = try DuckoCLI.Presence.parse(["away", "--for", "15m"])
        #expect(command.status == "away")
        #expect(command.hold == "15m")
        #expect(command.keepAlive == false)
    }

    @Test func `parse --keep-alive with status`() throws {
        let command = try DuckoCLI.Presence.parse(["away", "--keep-alive"])
        #expect(command.status == "away")
        #expect(command.keepAlive)
        #expect(command.hold == nil)
    }

    @Test func `parse bare status without lifetime flags`() throws {
        let command = try DuckoCLI.Presence.parse(["away", "BRB"])
        #expect(command.status == "away")
        #expect(command.message == "BRB")
        #expect(command.hold == nil)
        #expect(command.keepAlive == false)
    }

    @Test func `--for and --keep-alive are mutually exclusive`() {
        expectParseError(DuckoCLI.Presence.self, ["away", "--for", "15m", "--keep-alive"], containing: "mutually exclusive")
    }

    @Test func `--for without a status fails validation`() {
        expectParseError(DuckoCLI.Presence.self, ["--for", "5m"], containing: "require a status")
    }

    @Test func `--keep-alive without a status fails validation`() {
        expectParseError(DuckoCLI.Presence.self, ["--keep-alive"], containing: "require a status")
    }

    @Test func `invalid status with --for fails at validation`() {
        expectParseError(DuckoCLI.Presence.self, ["bogus", "--for", "1m"], containing: "Invalid presence status")
    }

    @Test func `offline with --for is rejected`() {
        expectParseError(DuckoCLI.Presence.self, ["offline", "--for", "1h"], containing: "offline cannot be held")
    }

    @Test func `offline with --keep-alive is rejected`() {
        expectParseError(DuckoCLI.Presence.self, ["offline", "--keep-alive"], containing: "offline cannot be held")
    }

    @Test func `malformed --for duration fails at validation`() {
        expectParseError(DuckoCLI.Presence.self, ["away", "--for", "soon"], containing: "Invalid duration")
    }

    @Test func `--hold is an unknown flag`() {
        expectParseError(DuckoCLI.Presence.self, ["away", "--hold", "5m"], containing: "hold")
    }
}

// MARK: - HoldDurationParsingTests

struct HoldDurationParsingTests {
    @Test func `parse seconds`() throws {
        #expect(try parseHoldDuration("30s") == .seconds(30))
    }

    @Test func `parse minutes`() throws {
        #expect(try parseHoldDuration("15m") == .seconds(15 * 60))
    }

    @Test func `parse hours`() throws {
        #expect(try parseHoldDuration("2h") == .seconds(2 * 3600))
    }

    @Test func `parse the 24h cap`() throws {
        #expect(try parseHoldDuration("24h") == .seconds(24 * 3600))
    }

    @Test(arguments: [
        "", // empty
        "30", // bare number, no unit
        "m", // unit only, no value
        "1h30m", // compound form
        "0s", // non-positive
        "-5m", // leading sign
        "+5m", // leading sign
        "5 m", // internal whitespace
        "5x", // unknown unit
        "99h", // exceeds the 24h cap
        "9223372036854775807h" // overflows on multiply
    ])
    func `parse rejects invalid token`(token: String) {
        #expect(throws: CLIError.self) {
            _ = try parseHoldDuration(token)
        }
    }

    @Test func `over-cap token reports durationTooLong`() {
        let error = #expect(throws: CLIError.self) {
            _ = try parseHoldDuration("99h")
        }
        guard case .durationTooLong = error else {
            Issue.record("expected .durationTooLong, got \(String(describing: error))")
            return
        }
    }

    @Test func `overflow token reports invalidDuration, not durationTooLong`() {
        let error = #expect(throws: CLIError.self) {
            _ = try parseHoldDuration("9223372036854775807h")
        }
        guard case .invalidDuration = error else {
            Issue.record("expected .invalidDuration, got \(String(describing: error))")
            return
        }
    }
}
