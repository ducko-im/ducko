import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct FormatterEventContractTests {
    private let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let peer = BareJID.parse("alice@example.com")!

    @Test func `event categories retain exact text ANSI and JSON envelopes`() throws {
        let full = try #require(FullJID.parse("alice@example.com/laptop"))
        let room = try #require(BareJID.parse("room@conference.example.com"))
        let account = accountID.uuidString
        let reset = "\u{001B}[0m"
        let cases: [EventExpectation] = [
            .init(.streamResumed(full), "stream resumed as alice@example.com/laptop", "\u{001B}[32mstream resumed as alice@example.com/laptop\(reset)",
                  ["type": "stream_resumed", "jid": full.description, "account": account]),
            .init(.authenticationFailed("denied"), "authentication failed: denied", "\u{001B}[31mauthentication failed: denied\(reset)",
                  ["type": "authentication_failed", "message": "denied", "account": account]),
            .init(.presenceSubscriptionApproved(from: peer), "Subscription approved by alice@example.com", "\u{001B}[32m✓ Subscription approved by alice@example.com\(reset)",
                  ["type": "subscription_approved", "from": peer.description]),
            .init(.presenceSubscriptionRevoked(from: peer), "Subscription revoked by alice@example.com", "\u{001B}[33m✗ Subscription revoked by alice@example.com\(reset)",
                  ["type": "subscription_revoked", "from": peer.description]),
            .init(.messageRetracted(originalID: "m1", from: .full(full)), "[retracted] message retracted by alice@example.com (id: m1)", "\u{001B}[2m⊘ message retracted by alice@example.com (id: m1)\(reset)",
                  ["type": "message_retracted", "original_id": "m1", "from": peer.description, "account": account]),
            .init(.messageModerated(originalID: "m1", moderator: "mod", room: room, reason: "reason"), "[moderated] message moderated by mod in room@conference.example.com (id: m1): reason", "\u{001B}[2m⊘ message moderated by mod in room@conference.example.com (id: m1): reason\(reset)",
                  ["type": "message_moderated", "original_id": "m1", "moderator": "mod", "room": room.description, "reason": "reason", "account": account]),
            .init(.jingleFileTransferCompleted(sid: "transfer", transport: .ibb), "Transfer completed: transfer — IBB", "\u{001B}[32m✅ Transfer completed: transfer — IBB\(reset)",
                  ["type": "jingle_transfer_completed", "sid": "transfer", "transport": "ibb", "account": account]),
            .init(.omemoDeviceListReceived(jid: peer, devices: [12, 34]), "OMEMO devices for alice@example.com: 12, 34", "\u{001B}[2mOMEMO devices for alice@example.com: 12, 34\(reset)",
                  ["type": "omemo_device_list", "jid": peer.description, "devices": "12,34", "account": account]),
            .init(.omemoSessionEstablished(jid: peer, deviceID: 12, identityKey: [0, 0xAB, 0xFF]), "OMEMO session established with alice@example.com device 12", "\u{001B}[32mOMEMO session established with alice@example.com device 12\(reset)",
                  ["type": "omemo_session_established", "jid": peer.description, "deviceID": "12", "fingerprint": "00abff", "account": account]),
            .init(.serviceOutageReceived(ServiceOutageInfo(description: "Maintenance", expectedEnd: "tomorrow", alternativeDomain: "other.example.com")), "Service outage: Maintenance (expected end: tomorrow) [alternative: other.example.com]", "\u{001B}[33mService outage: Maintenance (expected end: tomorrow) [alternative: other.example.com]\(reset)",
                  ["type": "service_outage", "description": "Maintenance", "expected_end": "tomorrow", "alternative_domain": "other.example.com", "account": account])
        ]
        for item in cases {
            #expect(PlainFormatter().formatEvent(item.event, accountID: accountID) == item.plain)
            #expect(ANSIFormatter().formatEvent(item.event, accountID: accountID) == item.ansi)
            let output = try #require(JSONFormatter().formatEvent(item.event, accountID: accountID))
            let actual = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
            #expect(actual == item.json)
        }
    }

    @Test func `ignored events stay silent in every formatter`() {
        let events: [XMPPEvent] = [
            .rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)),
            .chatStateChanged(from: peer, state: .composing),
            .pepItemsPublished(from: peer, node: "node", items: []),
            .pepItemsRetracted(from: peer, node: "node", itemIDs: ["id"]),
            .vcardAvatarHashReceived(from: peer, hash: "hash"),
            .blockListLoaded([peer]), .contactBlocked(peer), .contactUnblocked(peer),
            .mucSelfPingFailed(room: peer, reason: .notJoined),
            .omemoSessionAdvanced(jid: peer, deviceID: 12)
        ]
        for event in events {
            #expect(PlainFormatter().formatEvent(event, accountID: accountID) == nil)
            #expect(ANSIFormatter().formatEvent(event, accountID: accountID) == nil)
            #expect(JSONFormatter().formatEvent(event, accountID: accountID) == nil)
        }
    }

    @Test(arguments: ["incoming", "carbonReceived", "carbonSent", "room", "private"])
    func `message origins retain exact payload apart from bounded current timestamp`(origin: String) throws {
        let full = try #require(FullJID.parse("room@conference.example.com/alice"))
        var message = XMPPMessage(type: .chat)
        message.from = .full(full)
        message.to = .bare(peer)
        message.body = "hello"
        let forwarded = ForwardedMessage(message: message, timestamp: "2000-01-01T00:00:00Z")
        let event: XMPPEvent
        var json = ["type": "message", "direction": "incoming", "body": "hello", "account": accountID.uuidString]
        let human: String
        let color: String
        switch origin {
        case "carbonReceived":
            event = .messageCarbonReceived(forwarded)
            json["from"] = full.bareJID.description
            json["carbon"] = "true"
            human = "<- room@conference.example.com: hello [carbon]"
            color = "32"
        case "carbonSent":
            event = .messageCarbonSent(forwarded)
            json["to"] = peer.description
            json["direction"] = "outgoing"
            json["carbon"] = "true"
            human = "-> alice@example.com: hello [carbon]"
            color = "36"
        case "room", "private":
            event = origin == "room" ? .roomMessageReceived(message) : .mucPrivateMessageReceived(message)
            json["type"] = origin == "room" ? "room_message" : "muc_private_message"
            json["room"] = full.bareJID.description
            json["nickname"] = "alice"
            human = origin == "room" ? "<- room@conference.example.com/alice: hello" : "<- [PM] room@conference.example.com/alice: hello"
            color = origin == "room" ? "32" : "36"
        default:
            event = .messageReceived(message)
            json["from"] = full.bareJID.description
            human = "<- room@conference.example.com: hello"
            color = "32"
        }
        try expectMessage(event, json: json, human: human, color: color)
    }

    @Test(arguments: [String?.some("hello"), nil])
    func `encrypted messages print as they arrive, marked encrypted`(body: String?) throws {
        let full = try #require(FullJID.parse("alice@example.com/laptop"))
        let event = XMPPEvent.omemoEncryptedMessageReceived(from: .full(full), decryptedBody: body, senderDeviceID: 12, stanzaID: "m1")
        var json = [
            "type": "message", "direction": "incoming", "from": peer.description, "body": body ?? "",
            "encrypted": "true", "account": accountID.uuidString
        ]
        if body == nil { json["undecryptable"] = "true" }
        let sender = "<- \(peer): "
        try expectMessage(
            event, json: json, human: sender + (body ?? "error: \(ChatMessage.undecryptableText)") + " [encrypted]", color: "32",
            ansiHuman: sender + (body ?? "\u{001B}[31merror: \(ChatMessage.undecryptableText)"),
            ansiTail: " \u{001B}[32m\u{001B}[2m[encrypted]\u{001B}[0m"
        )
    }

    private func expectMessage(
        _ event: XMPPEvent, json: [String: String], human: String, color: String, ansiHuman: String? = nil, ansiTail: String = ""
    ) throws {
        let before = Date().addingTimeInterval(-1)
        let plain = try #require(PlainFormatter().formatEvent(event, accountID: accountID))
        let ansi = try #require(ANSIFormatter().formatEvent(event, accountID: accountID))
        let encoded = try #require(JSONFormatter().formatEvent(event, accountID: accountID))
        let after = Date()
        var actual = try JSONDecoder().decode([String: String].self, from: Data(encoded.utf8))
        let timestamp = try #require(actual["timestamp"])
        actual["timestamp"] = nil
        try expectTimestamp(timestamp, between: before, and: after)
        #expect(actual == json)
        let plainEnd = try #require(plain.firstIndex(of: "]"))
        try expectTimestamp(String(plain[plain.index(after: plain.startIndex) ..< plainEnd]), between: before, and: after)
        #expect(String(plain[plain.index(after: plainEnd)...]) == " \(human)")
        let ansiPrefix = "\u{001B}[2m["
        #expect(ansi.hasPrefix(ansiPrefix))
        let content = ansi.dropFirst(ansiPrefix.count)
        let ansiEnd = try #require(content.firstIndex(of: "]"))
        try expectTimestamp(String(content[..<ansiEnd]), between: before, and: after)
        #expect(String(content[content.index(after: ansiEnd)...]) == "\u{001B}[0m \u{001B}[\(color)m\(ansiHuman ?? human)\u{001B}[0m\(ansiTail)")
    }

    private func expectTimestamp(_ value: String, between before: Date, and after: Date) throws {
        let formatter = ISO8601DateFormatter()
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        let date = try #require(formatter.date(from: value))
        #expect(date >= before && date <= after)
    }
}

private struct EventExpectation {
    let event: XMPPEvent
    let plain: String
    let ansi: String
    let json: [String: String]

    init(_ event: XMPPEvent, _ plain: String, _ ansi: String, _ json: [String: String]) {
        self.event = event
        self.plain = plain
        self.ansi = ansi
        self.json = json
    }
}
