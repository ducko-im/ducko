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
        (.omemoDevices(jid: "bob@example.com", accountID: accountID), ["type": "omemo_devices_empty", "account": accountID.uuidString, "jid": "bob@example.com"]),
        (.onlineContacts, ["type": "online_contacts_empty"]),
        (.transfers, ["type": "transfers_empty"]),
        (.affiliations(.admin, room: "chat@conference.example.com"), ["type": "affiliations_empty", "affiliation": "admin", "room": "chat@conference.example.com"]),
        (.roomConfig(room: "chat@conference.example.com"), ["type": "room_config_empty", "room": "chat@conference.example.com"]),
        (.connectionInfo, ["type": "tls_info_empty"]),
        (.ownAvatar, ["type": "own_avatar_empty"]),
        (.avatar(jid: "bob@example.com"), ["type": "avatar_empty", "jid": "bob@example.com"]),
        (.recentMessage(.retract), ["type": "recent_message_empty", "purpose": "retract"]),
        (.recentMessage(.edit), ["type": "recent_message_empty", "purpose": "edit"]),
        (.recentMessage(.reply), ["type": "recent_message_empty", "purpose": "reply"]),
        (.moderatableMessage, ["type": "moderatable_message_empty"])
    ])
    func `json empty result is a structured record`(result: CLIEmptyResult, expected: [String: String]) throws {
        let output = JSONFormatter().formatEmptyResult(result)
        expectSnakeCaseKeys(output)
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(object == expected)
    }

    @Test(arguments: [
        (CLIEmptyResult.omemoDevices(jid: "bob@example.com", accountID: accountID), "No known OMEMO devices for bob@example.com."),
        (.onlineContacts, "No contacts online."),
        (.transfers, "No active transfers."),
        (.affiliations(.member, room: "chat@conference.example.com"), "No members."),
        (.affiliations(.outcast, room: "chat@conference.example.com"), "No outcasts."),
        (.roomConfig(room: "chat@conference.example.com"), "No configuration fields."),
        (.connectionInfo, "No TLS connection info available."),
        (.ownAvatar, "No avatar set."),
        (.avatar(jid: "bob@example.com"), "No avatar found for bob@example.com."),
        (.recentMessage(.retract), "No recent outgoing message to retract."),
        (.recentMessage(.edit), "No recent outgoing message to edit."),
        (.recentMessage(.reply), "No recent incoming message to reply to."),
        (.moderatableMessage, "No moderatable message found.")
    ])
    func `plain and ansi empty results print the message`(result: CLIEmptyResult, message: String) {
        #expect(PlainFormatter().formatEmptyResult(result) == message)
        #expect(ANSIFormatter().formatEmptyResult(result) == message)
    }
}
