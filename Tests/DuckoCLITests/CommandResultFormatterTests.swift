import Foundation
import Testing
@testable import DuckoCLI

struct CommandResultFormatterTests {
    struct Expectation: Sendable, CustomTestStringConvertible {
        let result: CLICommandResult
        let text: String
        let json: [String: String]

        init(_ result: CLICommandResult, _ text: String, _ json: [String: String]) {
            self.result = result
            self.text = text
            self.json = json
        }

        var testDescription: String {
            text
        }
    }

    @Test(arguments: [
        Expectation(.unregisterCancelled, "Cancelled.", ["action": "unregister_account", "result": "cancelled"]),
        Expectation(.accountUnregistered(historyDeleted: false), "Account unregistered.",
                    ["action": "unregister_account", "result": "unregistered", "history_deleted": "false"]),
        Expectation(.accountUnregistered(historyDeleted: true), "Account unregistered.\nChat history deleted.",
                    ["action": "unregister_account", "result": "unregistered", "history_deleted": "true"]),
        Expectation(.registrationSubmitted, "Registration submitted successfully.", ["action": "submit_registration"]),
        Expectation(.passwordChanged, "Password changed.", ["action": "change_password"]),
        Expectation(.blocked(jid: "bob@example.com"), "Blocked bob@example.com.", ["action": "block", "jid": "bob@example.com"]),
        Expectation(.unblocked(jid: "bob@example.com"), "Unblocked bob@example.com.", ["action": "unblock", "jid": "bob@example.com"]),
        Expectation(.directTransferStarted(fileName: "a.txt", jid: "bob@example.com"), "Sending a.txt to bob@example.com directly. Use /transfers to check progress.",
                    ["action": "send_file_directly", "file_name": "a.txt", "jid": "bob@example.com"]),
        Expectation(.transferAccepted(offerID: "o1", directory: "/tmp/dl"), "Accepted file transfer: o1, saving to /tmp/dl",
                    ["action": "accept_transfer", "offer_id": "o1", "directory": "/tmp/dl"]),
        Expectation(.transferDeclined(offerID: "o1"), "Declined file transfer: o1", ["action": "decline_transfer", "offer_id": "o1"]),
        Expectation(.transferCanceled(fileName: "a.txt"), "Canceled file transfer: a.txt", ["action": "cancel_transfer", "file_name": "a.txt"]),
        Expectation(.messageRetracted(id: "m1"), "Retracted message: m1", ["action": "retract", "original_id": "m1"]),
        Expectation(.messageEdited(id: "m1"), "Edited message: m1", ["action": "edit", "original_id": "m1"]),
        Expectation(.preference(name: "Chat states", key: "chatstates", enabled: true, changed: true), "Chat states enabled.",
                    ["action": "set_preference", "key": "chatstates", "enabled": "true"]),
        Expectation(.preference(name: "Chat states", key: "chatstates", enabled: false, changed: true), "Chat states disabled.",
                    ["action": "set_preference", "key": "chatstates", "enabled": "false"]),
        Expectation(.preference(name: "Displayed markers", key: "markers", enabled: true, changed: false), "Displayed markers: on",
                    ["action": "get_preference", "key": "markers", "enabled": "true"]),
        Expectation(.preference(name: "Displayed markers", key: "markers", enabled: false, changed: false), "Displayed markers: off",
                    ["action": "get_preference", "key": "markers", "enabled": "false"]),
        Expectation(.encryption(jid: "bob@example.com", enabled: true), "Encryption enabled for bob@example.com.",
                    ["action": "set_encryption", "jid": "bob@example.com", "enabled": "true"]),
        Expectation(.encryption(jid: "bob@example.com", enabled: false), "Encryption disabled for bob@example.com.",
                    ["action": "set_encryption", "jid": "bob@example.com", "enabled": "false"]),
        Expectation(.omemoSetupRetried(accountID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!), "Retrying OMEMO setup.",
                    ["action": "retry_omemo_setup", "account": "00000000-0000-0000-0000-000000000001"]),
        Expectation(.directedPresenceSent(jid: "bob@example.com"), "Sent directed presence to bob@example.com.", ["action": "send_presence", "jid": "bob@example.com"]),
        Expectation(.subscriptionApproved(jid: "bob@example.com"), "Approved subscription from bob@example.com.",
                    ["action": "approve_subscription", "jid": "bob@example.com"]),
        Expectation(.subscriptionDenied(jid: "bob@example.com"), "Denied subscription from bob@example.com.", ["action": "deny_subscription", "jid": "bob@example.com"]),
        Expectation(.roomLeft(room: "r@muc.example.com"), "Left r@muc.example.com.", ["action": "leave_room", "room": "r@muc.example.com"]),
        Expectation(.roomDestroyed(room: "r@muc.example.com"), "Room r@muc.example.com destroyed.", ["action": "destroy_room", "room": "r@muc.example.com"]),
        Expectation(.currentRoom(room: "r@muc.example.com"), "Current room: r@muc.example.com", ["action": "current_room", "room": "r@muc.example.com"]),
        Expectation(.voiceChanged(nickname: "carol", granted: true), "Granted voice to carol.", ["action": "grant_voice", "nickname": "carol"]),
        Expectation(.voiceChanged(nickname: "carol", granted: false), "Revoked voice from carol.", ["action": "revoke_voice", "nickname": "carol"]),
        Expectation(.kicked(nickname: "carol", room: "r@muc.example.com"), "Kicked carol from r@muc.example.com.",
                    ["action": "kick", "nickname": "carol", "room": "r@muc.example.com"]),
        Expectation(.roomConfigSubmitted(room: "r@muc.example.com"), "Submitted default room configuration for r@muc.example.com.",
                    ["action": "submit_room_config", "room": "r@muc.example.com"]),
        Expectation(.moderated(serverID: "s1"), "Moderated message (server-id: s1).", ["action": "moderate", "original_id": "s1"]),
        Expectation(.privateMessageSent(nickname: "carol"), "PM to carol sent.", ["action": "send_private_message", "nickname": "carol"]),
        Expectation(.ownAvatar(hash: "abc"), "Own avatar hash: abc", ["action": "own_avatar", "hash": "abc"]),
        Expectation(.avatar(jid: "bob@example.com", hash: "abc", mimeType: "image/png", size: 42),
                    "Avatar for bob@example.com:\n  Hash: abc\n  Type: image/png\n  Size: 42 bytes",
                    ["action": "avatar", "jid": "bob@example.com", "hash": "abc", "mime_type": "image/png", "size": "42"]),
        Expectation(.avatarSaved(path: "/tmp/a.png", hash: "abc", mimeType: "image/png", size: 42),
                    "Saved avatar to /tmp/a.png\nHash: abc\nType: image/png\nSize: 42 bytes",
                    ["action": "save_avatar", "path": "/tmp/a.png", "hash": "abc", "mime_type": "image/png", "size": "42"]),
        Expectation(.avatarPublished(hash: "abc", size: 42), "Avatar published successfully.\nHash: abc\nSize: 42 bytes",
                    ["action": "publish_avatar", "hash": "abc", "size": "42"]),
        Expectation(.bookmarkAdded(jid: "r@muc.example.com"), "Added bookmark for r@muc.example.com.", ["action": "add_bookmark", "jid": "r@muc.example.com"]),
        Expectation(.bookmarkRemoved(jid: "r@muc.example.com"), "Removed bookmark for r@muc.example.com.", ["action": "remove_bookmark", "jid": "r@muc.example.com"]),
        Expectation(.accountRegistered(jid: "bob@example.com"), "Account registered: bob@example.com", ["action": "register_account", "jid": "bob@example.com"])
    ])
    func `a command result prints its text, and in JSON its action and fields beside the text`(expectation: Expectation) throws {
        #expect(PlainFormatter().formatCommandResult(expectation.result) == expectation.text)
        #expect(ANSIFormatter().formatCommandResult(expectation.result) == expectation.text)
        let output = JSONFormatter().formatCommandResult(expectation.result)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
        #expect(json == expectation.json.merging(["type": "command_result", "message": expectation.text]) { $1 })
    }

    @Test func `a usage line prints unchanged, and in JSON as an error record`() throws {
        let line = "Usage: send <jid> <message>"
        #expect(PlainFormatter().formatUsageError(line) == line)
        #expect(ANSIFormatter().formatUsageError(line) == line)
        let output = JSONFormatter().formatUsageError(line)
        expectSnakeCaseKeys(output)
        #expect(try JSONDecoder().decode([String: String].self, from: Data(output.utf8)) == ["type": "error", "message": line])
    }

    @Test func `help prints unchanged, and in JSON as one help record`() throws {
        let text = "Commands:\n  send <jid> <message>"
        #expect(PlainFormatter().formatHelp(text) == text)
        #expect(ANSIFormatter().formatHelp(text) == text)
        let output = JSONFormatter().formatHelp(text)
        expectSnakeCaseKeys(output)
        #expect(!output.contains("\n"))
        #expect(try JSONDecoder().decode([String: String].self, from: Data(output.utf8)) == ["type": "help", "text": text])
    }
}
