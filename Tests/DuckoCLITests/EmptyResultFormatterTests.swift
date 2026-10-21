import Foundation
import Testing
@testable import DuckoCLI

struct EmptyResultFormatterTests {
    private static let accountID = UUID()

    @Test(arguments: [
        (CLIEmptyResult.accounts, ["type": "accounts_empty"]),
        (.roster(accountID: accountID), ["type": "roster_empty", "account": accountID.uuidString]),
        (.bookmarks(accountID: accountID), ["type": "bookmarks_empty", "account": accountID.uuidString]),
        (.blockList(accountID: accountID), ["type": "block_list_empty", "account": accountID.uuidString]),
        (.rooms, ["type": "rooms_empty"]),
        (.roomParticipants(room: "chat@conference.example.com"), ["type": "room_participants_empty", "room": "chat@conference.example.com"]),
        (.channels, ["type": "searched_channels_empty"]),
        (.messages, ["type": "messages_empty"]),
        (.omemoIdentity(accountID: accountID), ["type": "omemo_identity_empty", "account": accountID.uuidString]),
        (.omemoDevices(jid: "bob@example.com", accountID: accountID), ["type": "omemo_devices_empty", "account": accountID.uuidString, "jid": "bob@example.com"])
    ])
    func `json empty result is a structured record`(result: CLIEmptyResult, expected: [String: String]) throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(JSONFormatter().formatEmptyResult(result).utf8)) as? [String: String])
        #expect(object == expected)
    }

    @Test func `plain and ansi empty results print the message`() {
        let result = CLIEmptyResult.omemoDevices(jid: "bob@example.com", accountID: Self.accountID)
        #expect(PlainFormatter().formatEmptyResult(result) == "No known OMEMO devices for bob@example.com.")
        #expect(ANSIFormatter().formatEmptyResult(result) == "No known OMEMO devices for bob@example.com.")
    }
}
