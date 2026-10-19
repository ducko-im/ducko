import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

// MARK: - PlainFormatter Room Tests

struct PlainRoomFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatRoom

    @Test func `format room with name`() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        #expect(output.contains("Chat Room"))
        #expect(output.contains("chat@conference.example.com"))
    }

    @Test func `format room without name`() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: nil)
        let output = formatter.formatRoom(room)
        #expect(output == "chat@conference.example.com")
    }

    // MARK: - formatRoomParticipant

    @Test func `format room participant with JID`() {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("alice"))
        #expect(output.contains("alice@example.com"))
        #expect(output.contains("[participant]"))
    }

    @Test func `format room participant without JID`() {
        let participant = RoomParticipant(nickname: "bob", affiliation: .none, role: .visitor)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("bob"))
        #expect(output.contains("[visitor]"))
        #expect(!output.contains("@"))
    }

    // MARK: - formatRoomParticipantGroupHeader

    @Test func `format room participant group header`() {
        let group = RoomParticipantGroup(affiliation: .owner, participants: [
            RoomParticipant(nickname: "admin", affiliation: .owner, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        #expect(output.contains("Owner"))
        #expect(output.contains("1"))
    }

    // MARK: - MUC Events

    @Test func `format event room joined`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupancy = RoomOccupancy(nickname: "alice", occupants: [
            RoomOccupant(nickname: "alice", affiliation: .member, role: .participant),
            RoomOccupant(nickname: "bob", affiliation: .member, role: .participant)
        ], subject: "Hello")
        let output = try #require(formatter.formatEvent(.roomJoined(room: room, occupancy: occupancy, isNewlyCreated: false), accountID: UUID()))
        #expect(output.contains("Joined"))
        #expect(output.contains("alice"))
        #expect(output.contains("2 participants"))
        #expect(output.contains("Hello"))
    }

    @Test func `format event room occupant joined`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        #expect(output.contains("charlie"))
        #expect(output.contains("joined"))
    }

    @Test func `format event room occupant left`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant, reason: nil, isSelf: false), accountID: UUID()))
        #expect(output.contains("charlie"))
        #expect(output.contains("left"))
    }

    @Test func `format event room occupant kicked with reason`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant, reason: .kicked(reason: "disruptive"), isSelf: false), accountID: UUID()))
        #expect(output.contains("charlie"))
        #expect(output.contains("was kicked"))
        #expect(output.contains("disruptive"))
    }

    @Test func `format event room occupant banned`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "spammer", affiliation: .none, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant, reason: .banned(reason: nil), isSelf: false), accountID: UUID()))
        #expect(output.contains("spammer"))
        #expect(output.contains("was banned"))
    }

    @Test func `format event room subject changed`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let setter = JID.parse("alice@example.com")
        let output = try #require(formatter.formatEvent(.roomSubjectChanged(room: room, subject: "New topic", setter: setter), accountID: UUID()))
        #expect(output.contains("topic changed"))
        #expect(output.contains("New topic"))
        #expect(output.contains("alice@example.com"))
    }

    @Test func `format event room invite received`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from, reason: "Come join us!")
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        #expect(output.contains("Room invite"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("chat@conference.example.com"))
        #expect(output.contains("Come join us!"))
    }

    @Test func `format event room message received`() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hello everyone!"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        #expect(output.contains("<-"))
        #expect(output.contains("alice"))
        #expect(output.contains("Hello everyone!"))
    }
}

// MARK: - ANSIFormatter Room Tests

struct ANSIRoomFormatterTests {
    let formatter = ANSIFormatter()

    @Test func `format room with name uses bold`() {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Chat Room"))
    }

    @Test func `format room participant uses green`() {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("alice"))
    }

    @Test func `format room participant group header uses bold`() {
        let group = RoomParticipantGroup(affiliation: .admin, participants: [
            RoomParticipant(nickname: "mod", affiliation: .admin, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Admin"))
    }

    @Test func `format event room occupant joined uses yellow`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
    }

    @Test func `format event room invite uses yellow with bold room`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from)
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("\u{001B}[1m")) // bold
    }

    @Test func `format event room message uses green`() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hi"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        #expect(output.contains("\u{001B}[32m")) // green
    }
}

// MARK: - JSONFormatter Room Tests

struct JSONRoomFormatterTests {
    let formatter = JSONFormatter()

    // MARK: - formatRoom

    @Test func `format room is valid JSON`() throws {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: "Chat Room")
        let output = formatter.formatRoom(room)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room")
        #expect(json["jid"] == "chat@conference.example.com")
        #expect(json["name"] == "Chat Room")
    }

    @Test func `format room without name omits name`() throws {
        let room = DiscoveredRoom(jidString: "chat@conference.example.com", name: nil)
        let output = formatter.formatRoom(room)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room")
        #expect(json["name"] == nil)
    }

    // MARK: - formatRoomParticipant

    @Test func `format room participant is valid JSON`() throws {
        let participant = RoomParticipant(nickname: "alice", jidString: "alice@example.com", affiliation: .member, role: .participant)
        let output = formatter.formatRoomParticipant(participant)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_participant")
        #expect(json["nickname"] == "alice")
        #expect(json["jid"] == "alice@example.com")
        #expect(json["role"] == "participant")
        #expect(json["affiliation"] == "member")
    }

    // MARK: - formatRoomParticipantGroupHeader

    @Test func `format room participant group header is valid JSON`() throws {
        let group = RoomParticipantGroup(affiliation: .owner, participants: [
            RoomParticipant(nickname: "admin", affiliation: .owner, role: .moderator),
            RoomParticipant(nickname: "admin2", affiliation: .owner, role: .moderator)
        ])
        let output = formatter.formatRoomParticipantGroupHeader(group)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_participant_group")
        #expect(json["affiliation"] == "Owner")
        #expect(json["count"] == "2")
    }

    // MARK: - MUC Events

    @Test func `format event room joined is valid JSON`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupancy = RoomOccupancy(nickname: "alice", occupants: [
            RoomOccupant(nickname: "alice", affiliation: .member, role: .participant)
        ], subject: "Topic")
        let output = try #require(formatter.formatEvent(.roomJoined(room: room, occupancy: occupancy, isNewlyCreated: false), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_joined")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["nickname"] == "alice")
        #expect(json["subject"] == "Topic")
    }

    @Test func `format event room occupant joined is valid JSON`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantJoined(room: room, occupant: occupant), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_occupant_joined")
        #expect(json["nickname"] == "charlie")
    }

    /// Like the other event flags, `self` appears only when it is set.
    @Test(arguments: [true, false])
    func `format event room occupant left is valid JSON`(isSelf: Bool) throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "charlie", affiliation: .member, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant, reason: nil, isSelf: isSelf), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_occupant_left")
        #expect(json["nickname"] == "charlie")
        #expect(json["self"] == (isSelf ? "true" : nil))
    }

    @Test(arguments: [true, false])
    func `format event of a nickname change marks the user's own`(isSelf: Bool) throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "me2", affiliation: .member, role: .participant)
        let event = XMPPEvent.roomOccupantNickChanged(room: room, oldNickname: "me", occupant: occupant, isSelf: isSelf)
        let output = try #require(formatter.formatEvent(event, accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_nick_changed")
        #expect(json["self"] == (isSelf ? "true" : nil))
    }

    @Test func `format event room occupant kicked is valid JSON`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let occupant = RoomOccupant(nickname: "troublemaker", affiliation: .none, role: .participant)
        let output = try #require(formatter.formatEvent(.roomOccupantLeft(room: room, occupant: occupant, reason: .kicked(reason: "disruptive"), isSelf: false), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_occupant_left")
        #expect(json["nickname"] == "troublemaker")
        #expect(json["leave_reason"] == "kicked")
        #expect(json["reason_text"] == "disruptive")
    }

    @Test func `format event room subject changed is valid JSON`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let setter = JID.parse("alice@example.com")
        let output = try #require(formatter.formatEvent(.roomSubjectChanged(room: room, subject: "New topic", setter: setter), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_subject_changed")
        #expect(json["subject"] == "New topic")
        #expect(json["setter"] == "alice@example.com")
    }

    @Test func `format event room invite is valid JSON`() throws {
        let room = try #require(BareJID.parse("chat@conference.example.com"))
        let from = try #require(JID.parse("bob@example.com"))
        let invite = RoomInvite(room: room, from: from, reason: "Join us")
        let output = try #require(formatter.formatEvent(.roomInviteReceived(invite), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_invite")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["from"] == "bob@example.com")
        #expect(json["reason"] == "Join us")
    }

    @Test func `format event room message is valid JSON`() throws {
        var message = XMPPMessage(type: .groupchat)
        message.from = JID.parse("chat@conference.example.com/alice")
        message.body = "Hello everyone!"
        let output = try #require(formatter.formatEvent(.roomMessageReceived(message), accountID: UUID()))
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "room_message")
        #expect(json["direction"] == "incoming")
        #expect(json["room"] == "chat@conference.example.com")
        #expect(json["nickname"] == "alice")
        #expect(json["body"] == "Hello everyone!")
    }
}
