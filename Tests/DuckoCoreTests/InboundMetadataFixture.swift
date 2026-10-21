import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

enum InboundMetadataOrigin {
    case live, carbonReceived, carbonSent, room, privateRoom
}

@MainActor
func verifyPersistedInboundMetadata(origin: InboundMetadataOrigin, hasReply: Bool) async throws {
    try await withTemporaryDirectory { directory in
        let store = MockPersistenceStore()
        let transcripts = FileTranscriptStore(baseDirectory: directory)
        let environment = AppEnvironment(store: store, transcripts: transcripts, credentialStore: NullCredentialStore())
        let accountID = try await environment.accountService.createAccount(jidString: "alice@example.com")
        let stanza = try metadataStanza(origin: origin, hasReply: hasReply)
        let event: XMPPEvent = switch origin {
        case .live: .messageReceived(stanza)
        case .carbonReceived: .messageCarbonReceived(ForwardedMessage(message: stanza, timestamp: "2026-02-28T10:00:00Z"))
        case .carbonSent: .messageCarbonSent(ForwardedMessage(message: stanza, timestamp: "2026-02-28T10:00:00Z"))
        case .room: .roomMessageReceived(stanza)
        case .privateRoom: .mucPrivateMessageReceived(stanza)
        }
        await environment.chatService.handleEvent(event, accountID: accountID)
        let conversation = try #require(try await store.fetchConversations(for: accountID).first)
        // A newly opened store decodes the actual JSONL produced by ingestion.
        let reloaded = FileTranscriptStore(baseDirectory: directory)
        let message = try #require(try await reloaded.fetchMessages(for: conversation.id, before: nil, limit: 10).first)
        #expect(message.stanzaID == "incoming-id")
        #expect(message.replyToID == (hasReply ? "original-id" : nil))
        #expect(message.replyToJID == (hasReply ? "bob@example.com" : nil))
        #expect(message.body == (hasReply ? "> earlier\nreply body" : "reply body"))
        #expect(message.replyFallbackRange == (hasReply ? 0 ..< 10 : nil))
        #expect(message.attachments.count == 1)
        #expect(message.attachments.first?.url == "https://example.com/image.png")
        #expect(message.attachments.first?.mimeType == "image/png")
        #expect(message.attachments.first?.oobDescription == "image description")
        #expect(message.attachments.first?.origin == .remote)
        switch origin {
        case .live, .carbonReceived, .carbonSent: #expect(message.serverID == "trusted-id")
        case .room: #expect(message.serverID == "room-id")
        case .privateRoom:
            #expect(message.serverID == "trusted-id")
            #expect(conversation.occupantNickname == "Bob")
        }
        #expect(message.isOutgoing == (origin == .carbonSent))
        await environment.shutdown(within: .seconds(2))
    }
}

private func metadataStanza(origin: InboundMetadataOrigin, hasReply: Bool) throws -> XMPPMessage {
    let account = try #require(BareJID.parse("alice@example.com"))
    let peer = try #require(BareJID.parse("bob@example.com"))
    let room = try #require(BareJID.parse("room@conference.example.com"))
    let outgoing = origin == .carbonSent
    let sender: BareJID = switch origin {
    case .live, .carbonReceived: peer
    case .carbonSent: account
    case .room, .privateRoom: room
    }
    var stanza = XMPPMessage(type: origin == .room ? .groupchat : .chat, to: .bare(outgoing ? peer : account), id: "incoming-id")
    stanza.from = try .full(#require(FullJID(bareJID: sender, resourcePart: "Bob")))
    let reply = MessageReply(to: "original-id", by: .bare(peer), quoting: "earlier")
    stanza.body = hasReply ? reply.body(replying: "reply body") : "reply body"
    if hasReply {
        for element in reply.elements {
            stanza.element.addChild(element)
        }
    }
    for (id, by) in [("forged-id", peer.description), ("trusted-id", account.description), ("room-id", room.description)] {
        stanza.element.addChild(DuckoXMPP.XMLElement(name: "stanza-id", namespace: XMPPNamespaces.stanzaID, attributes: ["id": id, "by": by]))
    }
    for link in ["https://example.com/image.png", "file:///private/recipient-document.txt"] {
        var oob = DuckoXMPP.XMLElement(name: "x", namespace: XMPPNamespaces.oob)
        var url = DuckoXMPP.XMLElement(name: "url")
        url.addText(link)
        oob.addChild(url)
        var description = DuckoXMPP.XMLElement(name: "desc")
        description.addText("image description")
        oob.addChild(description)
        stanza.element.addChild(oob)
    }
    return stanza
}
