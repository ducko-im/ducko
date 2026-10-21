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
        let occupant = try #require(FullJID.parse("room@conference.example.com/alice"))
        let account = accountID.uuidString
        let reset = "\u{001B}[0m"
        let refusal = "Sign-in refused: the server offers only a sign-in that sends the password, and this account has signed in without sending it before"
        let cases: [EventExpectation] = [
            .init(.streamResumed(full), "stream resumed as alice@example.com/laptop", "\u{001B}[32mstream resumed as alice@example.com/laptop\(reset)",
                  ["type": "stream_resumed", "jid": full.description, "account": account]),
            .init(.authenticationFailed("denied"), "authentication failed: denied", "\u{001B}[31mauthentication failed: denied\(reset)",
                  ["type": "authentication_failed", "message": "denied", "account": account]),
            .init(.plainSignInRefused, "\(refusal). Run 'ducko account reset-security <jid>' to send the password anyway.",
                  "\u{001B}[31m\(refusal). Run 'ducko account reset-security <jid>' to send the password anyway.\(reset)",
                  ["type": "sign_in_refused", "reason": "plain_after_scram", "message": refusal, "account": account]),
            .init(.presenceSubscriptionApproved(from: peer), "Subscription approved by alice@example.com", "\u{001B}[32m✓ Subscription approved by alice@example.com\(reset)",
                  ["type": "subscription_approved", "from": peer.description]),
            .init(.presenceSubscriptionRevoked(from: peer), "Subscription revoked by alice@example.com", "\u{001B}[33m✗ Subscription revoked by alice@example.com\(reset)",
                  ["type": "subscription_revoked", "from": peer.description]),
            .init(.messageRetracted(originalID: "m1", from: .full(full), messageType: .chat), "[retracted] message retracted by alice@example.com (id: m1)", "\u{001B}[2m⊘ message retracted by alice@example.com (id: m1)\(reset)",
                  ["type": "message_retracted", "original_id": "m1", "from": peer.description, "message_type": "chat", "account": account]),
            .init(.messageCorrected(originalID: "m1", newBody: "fixed", replyFallbackRange: nil, from: .full(occupant), messageType: .groupchat), "message corrected by room@conference.example.com: fixed", "\u{001B}[33mmessage corrected by room@conference.example.com: fixed\(reset)",
                  ["type": "message_corrected", "originalID": "m1", "newBody": "fixed", "from": room.description, "message_type": "groupchat", "account": account]),
            .init(.messageModerated(originalID: "m1", moderator: "mod", room: room, reason: "reason"), "[moderated] message moderated by mod in room@conference.example.com (id: m1): reason", "\u{001B}[2m⊘ message moderated by mod in room@conference.example.com (id: m1): reason\(reset)",
                  ["type": "message_moderated", "original_id": "m1", "moderator": "mod", "room": room.description, "reason": "reason", "account": account]),
            .init(.jingleFileTransferCompleted(sid: "transfer", transport: .ibb), "Transfer completed: transfer — IBB", "\u{001B}[32m✅ Transfer completed: transfer — IBB\(reset)",
                  ["type": "jingle_transfer_completed", "sid": "transfer", "transport": "ibb", "account": account]),
            .init(.omemoDeviceListReceived(jid: peer, devices: [12, 34]), "OMEMO devices for alice@example.com: 12, 34", "\u{001B}[2mOMEMO devices for alice@example.com: 12, 34\(reset)",
                  ["type": "omemo_device_list", "jid": peer.description, "devices": "12,34", "account": account]),
            .init(.omemoSessionEstablished(jid: peer, deviceID: 12, identityKey: [0, 0xAB, 0xFF], consumedPreKeyID: 7), "OMEMO session established with alice@example.com device 12", "\u{001B}[32mOMEMO session established with alice@example.com device 12\(reset)",
                  ["type": "omemo_session_established", "jid": peer.description, "deviceID": "12", "fingerprint": "00abff", "account": account])
        ]
        for item in cases {
            #expect(PlainFormatter().formatEvent(item.event, accountID: accountID) == item.plain)
            #expect(ANSIFormatter().formatEvent(item.event, accountID: accountID) == item.ansi)
            let output = try #require(JSONFormatter().formatEvent(item.event, accountID: accountID))
            let actual = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
            #expect(actual == item.json)
        }
    }

    @Test func `ignored events stay silent in every formatter`() throws {
        let device = try #require(FullJID.parse("alice@example.com/laptop"))
        // A retraction's body is only the fallback for clients that cannot retract.
        var retraction = XMPPMessage(type: .chat, to: .bare(peer), id: "r1")
        retraction.from = .full(device)
        retraction.body = "This person attempted to retract a previous message, but it's unsupported by your client."
        retraction.element.addChild(DuckoXMPP.XMLElement(name: "retract", namespace: XMPPNamespaces.messageRetract, attributes: ["id": "m1"]))
        // An encrypted message's body and links are outside its encryption. It prints once stored, through
        // `formatEncryptedMessage`.
        var omemo = XMPPMessage(type: .chat, to: .bare(peer), id: "e1")
        omemo.from = .full(device)
        omemo.element.addChild(DuckoXMPP.XMLElement(name: "encrypted", namespace: XMPPNamespaces.omemo))
        var link = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        link.setChildText(named: "url", to: "https://example.com/file.png")
        omemo.element.addChild(link)
        var otherMethod = XMPPMessage(type: .chat, to: .bare(peer), id: "e2")
        otherMethod.from = .full(device)
        otherMethod.body = "fallback"
        otherMethod.element.addChild(DuckoXMPP.XMLElement(name: "encryption", namespace: XMPPNamespaces.eme, attributes: ["namespace": "urn:xmpp:otr:0"]))
        let events: [XMPPEvent] = [
            .messageCarbonReceived(ForwardedMessage(message: retraction, timestamp: nil)),
            .messageCarbonSent(ForwardedMessage(message: retraction, timestamp: nil)),
            .messageCarbonReceived(ForwardedMessage(message: omemo, timestamp: nil)),
            .messageCarbonSent(ForwardedMessage(message: omemo, timestamp: nil)),
            .messageCarbonReceived(ForwardedMessage(message: otherMethod, timestamp: nil)),
            .rosterUpdated(RosterUpdate(receipt: 1, origin: .initial, contents: .snapshot([]), version: nil)),
            .chatStateChanged(from: .bare(peer), state: .composing, messageType: .chat),
            .pepItemsPublished(from: peer, node: "node", items: []),
            .pepItemsRetracted(from: peer, node: "node", itemIDs: ["id"]),
            .vcardAvatarHashReceived(from: .bare(peer), hash: "hash"),
            .blockListLoaded([.bare(peer), .full(device)]), .contactBlocked(.full(device)), .contactUnblocked(.bare(peer)),
            .mucSelfPingFailed(room: peer, reason: .notJoined),
            .omemoSessionAdvanced(jid: peer, deviceID: 12),
            // Printed once stored, through `formatEncryptedMessage`, so a copy already stored prints nothing.
            .omemoEncryptedMessageReceived(message: XMPPMessage(type: .chat, id: "m1"), outcome: .undecryptable(.notForThisDevice))
        ]
        for event in events {
            #expect(PlainFormatter().formatEvent(event, accountID: accountID) == nil)
            #expect(ANSIFormatter().formatEvent(event, accountID: accountID) == nil)
            #expect(JSONFormatter().formatEvent(event, accountID: accountID) == nil)
        }
    }

    @Test(arguments: ["incoming", "carbonReceived", "carbonSent", "room", "private"])
    func `message origins retain exact payload and the time the message was sent`(origin: String) throws {
        let full = try #require(FullJID.parse("room@conference.example.com/alice"))
        let stamp = "2000-01-01T00:00:00Z"
        var message = XMPPMessage(type: origin == "room" ? .groupchat : .chat)
        message.from = .full(full)
        message.to = .bare(peer)
        message.body = "hello"
        // Live messages carry the delay of the account's server, or of the room for room messages; carbons their own.
        let stamper = origin == "room" ? full.bareJID.description : peer.domainPart
        message.element.addChild(DuckoXMPP.XMLElement(name: "delay", namespace: XMPPNamespaces.delay, attributes: ["from": stamper, "stamp": stamp]))
        let forwarded = ForwardedMessage(message: message, timestamp: stamp)
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
        try expectMessage(
            { $0.formatEvent(event, accountID: accountID) }, json: json, human: human, color: color, sentAt: Date(timeIntervalSince1970: 946_684_800)
        )
    }

    enum EncryptedCase: CaseIterable {
        case chat, undecryptable, otherMethod, room, privateRoom
    }

    @Test(arguments: EncryptedCase.allCases)
    func `encrypted messages print as they are stored, marked encrypted, a room's as a room line`(kind: EncryptedCase) throws {
        let room = try #require(BareJID.parse("room@conference.example.com"))
        let reason: UndecryptableReason? = switch kind {
        case .undecryptable: .notForThisDevice
        case .otherMethod: .otherMethod(name: "OpenPGP for XMPP")
        case .chat, .room, .privateRoom: nil
        }
        let isRoom = kind == .room || kind == .privateRoom
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), stanzaID: "m1", fromJID: isRoom ? "bob" : peer.description, body: reason == nil ? "hello" : "",
            timestamp: Date(), isOutgoing: false, isDelivered: false, isEdited: false, type: kind == .room ? "groupchat" : "chat",
            isEncrypted: true, isUndecryptable: reason != nil, undecryptableReason: reason
        )
        let conversation = Conversation(
            id: message.conversationID, accountID: accountID, jid: isRoom ? room : peer, type: kind == .room ? .groupchat : .chat,
            isPinned: false, isMuted: false, unreadCount: 0, occupantNickname: kind == .privateRoom ? "bob" : nil, createdAt: Date()
        )
        var json = ["direction": "incoming", "body": message.body, "encrypted": "true", "account": accountID.uuidString]
        switch kind {
        case .room: json.merge(["type": "room_message", "room": room.description, "nickname": "bob"]) { $1 }
        case .privateRoom: json.merge(["type": "muc_private_message", "room": room.description, "nickname": "bob"]) { $1 }
        case .chat, .undecryptable, .otherMethod: json.merge(["type": "message", "from": peer.description]) { $1 }
        }
        if let reason {
            json["undecryptable"] = "true"
            json["notice"] = reason.text
        }
        let sender = switch kind {
        case .room: "<- room@conference.example.com/bob: "
        case .privateRoom: "<- [PM] room@conference.example.com/bob: "
        case .chat, .undecryptable, .otherMethod: "<- \(peer): "
        }
        try expectMessage(
            { $0.formatEncryptedMessage(message, in: conversation, accountID: accountID) }, json: json,
            human: sender + (reason.map { "error: \($0.text)" } ?? "hello") + " [encrypted]", color: "32",
            ansiHuman: sender + (reason.map { "\u{001B}[31merror: \($0.text)" } ?? "hello"),
            ansiTail: " \u{001B}[32m\u{001B}[2m[encrypted]\u{001B}[0m"
        )
    }

    private func expectMessage(
        _ format: (any CLIFormatter) -> String?, json: [String: String], human: String, color: String,
        ansiHuman: String? = nil, ansiTail: String = "", sentAt: Date? = nil
    ) throws {
        let before = sentAt ?? Date().addingTimeInterval(-1)
        let plain = try #require(format(PlainFormatter()))
        let ansi = try #require(format(ANSIFormatter()))
        let encoded = try #require(format(JSONFormatter()))
        let after = sentAt ?? Date()
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
