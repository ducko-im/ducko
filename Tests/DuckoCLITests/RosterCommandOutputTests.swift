import ArgumentParser
import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

@MainActor
struct RosterCommandOutputTests {
    @Test(arguments: [RosterCommandOutcome.LocalStatus.synchronized, .incomplete, .different])
    func `finite command prints one outcome and exits only after teardown`(status: RosterCommandOutcome.LocalStatus) async throws {
        let outcome = RosterCommandOutcome(operation: .remove, accountID: UUID(), jid: "bob@example.com", localStatus: status, subscriptionStatus: .notRequested)
        var tornDown = false
        var lines: [String] = []
        do {
            try await RosterCommandOutput.run(formatter: JSONFormatter(), output: {
                #expect(tornDown)
                lines.append($0)
            }, operation: {
                try await ConnectedOperation.run(connect: {}, ready: {}, operation: { outcome }, teardown: { tornDown = true })
            })
            #expect(status == .synchronized)
        } catch let code as ExitCode {
            #expect(code == ExitCode(3))
            #expect(status != .synchronized)
        }
        #expect(lines.count == 1)
        expectSnakeCaseKeys(lines[0])
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(object["operation"] == "remove")
        #expect(object["account"] == outcome.accountID.uuidString)
        #expect(object["jid"] == outcome.jid)
        #expect(object["remote_status"] == "confirmed")
        #expect(object["local_status"] == status.rawValue)
        #expect(object["result"] == (outcome.isComplete ? "complete" : "partial"))
        #expect(object["subscription_status"] == "not_requested")
    }

    @Test(arguments: [(RosterCommandError.RemoteStatus.notSent, "not_sent"), (.rejected, "rejected"), (.unconfirmed, "unconfirmed")])
    func `preconfirmation errors retain structured remote status`(status: RosterCommandError.RemoteStatus, expected: String) async throws {
        let error = RosterCommandError(operation: .add, accountID: UUID(), jid: "bob@example.com", status: status, detail: "Controlled fixture")
        var lines: [String] = []
        await #expect(throws: ExitCode.failure) {
            try await RosterCommandOutput.run(formatter: JSONFormatter(), output: { lines.append($0) }, operation: { throw error })
        }
        #expect(lines.count == 1)
        expectSnakeCaseKeys(lines[0])
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        #expect(object["remote_status"] == expected)
        #expect(object["type"] == "error")
        #expect(object["local_status"] == "not_started")
        #expect(object["subscription_status"] == "not_requested")
        #expect(object["jid"] == error.jid)
    }

    @Test(arguments: [RosterCommandOutcome.LocalStatus.synchronized, .incomplete, .different])
    func `human and structured formatters report the same outcome`(status: RosterCommandOutcome.LocalStatus) throws {
        let outcome = RosterCommandOutcome(operation: .add, accountID: UUID(), jid: "bob@example.com", localStatus: status, subscriptionStatus: .incomplete)
        #expect(!outcome.isComplete)
        #expect(PlainFormatter().formatRosterCommand(outcome) == outcome.message)
        #expect(ANSIFormatter().formatRosterCommand(outcome).contains(outcome.message))
        let output = JSONFormatter().formatRosterCommand(outcome)
        expectSnakeCaseKeys(output)
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(object["message"] == outcome.message)
        #expect(object["subscription_status"] == "incomplete")
        #expect(object["result"] == "partial")
    }
}
