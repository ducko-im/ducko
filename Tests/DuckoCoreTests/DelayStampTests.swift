import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Which delay on a live message tells when it was sent.
struct DelayStampTests {
    private static let account = BareJID(localPart: "alice", domainPart: "example.com")!
    private static let room = BareJID(localPart: "room", domainPart: "conference.example.com")!
    private static let sentTime = Date(timeIntervalSince1970: 1_772_359_200)
    private static let receivedAt = sentTime.addingTimeInterval(3600)

    private static func message(type: XMPPMessage.MessageType = .chat, from: JID, delays: [[String: String]]) -> XMPPMessage {
        var message = XMPPMessage(type: type, to: .bare(account))
        message.from = from
        for attributes in delays {
            message.element.addChild(DuckoXMPP.XMLElement(name: "delay", namespace: XMPPNamespaces.delay, attributes: attributes))
        }
        return message
    }

    private static func stamp(_ message: XMPPMessage) -> DelayStamp? {
        DelayStamp(in: message, accountJID: account, receivedAt: receivedAt)
    }

    @Test func `the account's server's delay is the sent time, whichever of several delays it is`() throws {
        let contact = try #require(FullJID.parse("bob@example.org/phone"))
        let message = Self.message(from: .full(contact), delays: [
            ["from": "bob@example.org", "stamp": "2026-03-01T08:00:00Z"],
            ["from": "example.com", "stamp": "2026-03-01T10:00:00.000Z"]
        ])

        let stamp = try #require(Self.stamp(message))

        #expect(stamp.sentTime == Self.sentTime)
        #expect(!stamp.isFromRoom)
    }

    @Test(arguments: [
        ["from": "bob@example.org", "stamp": "2026-03-01T10:00:00Z"],
        ["stamp": "2026-03-01T10:00:00Z"],
        ["from": "example.com", "stamp": "yesterday"]
    ])
    func `a delay from anyone else, from no one, or without a readable stamp is ignored`(attributes: [String: String]) throws {
        let contact = try #require(FullJID.parse("bob@example.org/phone"))

        #expect(Self.stamp(Self.message(from: .full(contact), delays: [attributes])) == nil)
    }

    @Test func `the room's delay is the sent time of its groupchat messages only`() throws {
        let occupant = try #require(FullJID(bareJID: Self.room, resourcePart: "bob"))
        let delays = [["from": Self.room.description, "stamp": "2026-03-01T10:00:00Z"]]

        let stamp = try #require(Self.stamp(Self.message(type: .groupchat, from: .full(occupant), delays: delays)))

        #expect(stamp.sentTime == Self.sentTime)
        #expect(stamp.isFromRoom)
        #expect(Self.stamp(Self.message(type: .chat, from: .full(occupant), delays: delays)) == nil)
    }

    @Test func `a stamp later than the arrival is the arrival`() throws {
        let contact = try #require(FullJID.parse("bob@example.org/phone"))
        let message = Self.message(from: .full(contact), delays: [["from": "example.com", "stamp": "2030-01-01T00:00:00Z"]])

        #expect(Self.stamp(message)?.sentTime == Self.receivedAt)
    }
}
