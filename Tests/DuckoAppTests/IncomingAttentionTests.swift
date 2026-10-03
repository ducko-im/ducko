import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoApp

struct IncomingAttentionTests {
    private static func makeConversation(
        type: Conversation.ConversationType = .chat, isMuted: Bool = false, occupantNickname: String? = nil
    ) -> Conversation {
        Conversation(
            id: UUID(), accountID: UUID(), jid: BareJID(localPart: "friend", domainPart: "example.com")!, type: type,
            isPinned: false, isMuted: isMuted, unreadCount: 0, occupantNickname: occupantNickname, createdAt: Date()
        )
    }

    private static func makeMessage(in conversation: Conversation, isOutgoing: Bool = false) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversation.id, fromJID: conversation.jid.description, body: "hi",
            timestamp: Date(), isOutgoing: isOutgoing, isDelivered: false, isEdited: false, type: "chat"
        )
    }

    @Test func `a roster contact's message opens their chat quietly and notifies`() {
        let conversation = Self.makeConversation()

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation), in: conversation, isFromRosterContact: true, isInView: false
        )

        #expect(attention == IncomingAttention(opensChatQuietly: true, notifies: true))
    }

    @Test func `a message in the chat in view opens it but posts no notification`() {
        let conversation = Self.makeConversation()

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation), in: conversation, isFromRosterContact: true, isInView: true
        )

        #expect(attention == IncomingAttention(opensChatQuietly: true, notifies: false))
    }

    @Test func `a stranger's message notifies without opening a chat`() {
        let conversation = Self.makeConversation()

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation), in: conversation, isFromRosterContact: false, isInView: false
        )

        #expect(attention == IncomingAttention(opensChatQuietly: false, notifies: true))
    }

    @Test(arguments: [
        (Conversation.ConversationType.groupchat, nil as String?),
        (Conversation.ConversationType.chat, "occupant" as String?)
    ])
    func `a room's message, and one from a room's occupant, opens no chat`(
        type: Conversation.ConversationType, occupantNickname: String?
    ) {
        let conversation = Self.makeConversation(type: type, occupantNickname: occupantNickname)

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation), in: conversation, isFromRosterContact: true, isInView: false
        )

        #expect(attention == IncomingAttention(opensChatQuietly: false, notifies: true))
    }

    @Test func `the user's own message opens no chat`() {
        let conversation = Self.makeConversation()

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation, isOutgoing: true), in: conversation, isFromRosterContact: true, isInView: false
        )

        #expect(!attention.opensChatQuietly)
    }

    @Test func `a muted chat's message does nothing`() {
        let conversation = Self.makeConversation(isMuted: true)

        let attention = IncomingAttention.forMessage(
            Self.makeMessage(in: conversation), in: conversation, isFromRosterContact: true, isInView: false
        )

        #expect(attention == IncomingAttention())
    }

    @Test func `a roster contact's file offer opens their chat quietly and notifies, with or without a chat yet`() {
        let expected = IncomingAttention(opensChatQuietly: true, notifies: true)

        #expect(IncomingAttention.forFileOffer(in: nil, isFromRosterContact: true, isInView: false) == expected)
        #expect(IncomingAttention.forFileOffer(in: Self.makeConversation(), isFromRosterContact: true, isInView: false) == expected)
    }

    @Test func `a stranger's file offer notifies without opening a chat`() {
        let attention = IncomingAttention.forFileOffer(in: nil, isFromRosterContact: false, isInView: false)

        #expect(attention == IncomingAttention(opensChatQuietly: false, notifies: true))
    }

    @Test func `a file offer in the chat in view posts no notification`() {
        let attention = IncomingAttention.forFileOffer(in: Self.makeConversation(), isFromRosterContact: true, isInView: true)

        #expect(attention == IncomingAttention(opensChatQuietly: true, notifies: false))
    }

    @Test func `a muted chat's file offer does nothing`() {
        let attention = IncomingAttention.forFileOffer(
            in: Self.makeConversation(isMuted: true), isFromRosterContact: true, isInView: false
        )

        #expect(attention == IncomingAttention())
    }

    @Test func `a file offer's chat is the one with its sender alone, on the offer's account`() {
        let accountID = UUID()
        var (chat, room, occupantChat) = (
            Self.makeConversation(), Self.makeConversation(type: .groupchat), Self.makeConversation(occupantNickname: "friend")
        )
        chat.accountID = accountID
        room.accountID = accountID
        occupantChat.accountID = accountID
        let jid = chat.jid.description

        #expect(IncomingAttention.chat(withSender: jid, accountID: accountID, among: [room, occupantChat, chat])?.id == chat.id)
        #expect(IncomingAttention.chat(withSender: jid, accountID: accountID, among: [room, occupantChat]) == nil)
        #expect(IncomingAttention.chat(withSender: jid, accountID: UUID(), among: [chat]) == nil)
        #expect(IncomingAttention.chat(withSender: "other@example.com", accountID: accountID, among: [chat]) == nil)
    }

    @Test func `a notification is titled with the chat's own name, else the roster name, else the chat's short title`() {
        var named = Self.makeConversation()
        named.displayName = "Friend at work"
        let unnamed = Self.makeConversation()
        let jid = "friend@example.com"

        #expect(IncomingAttention.senderName(in: named, rosterName: "Best Friend", jidString: jid) == "Friend at work")
        #expect(IncomingAttention.senderName(in: unnamed, rosterName: "Best Friend", jidString: jid) == "Best Friend")
        #expect(IncomingAttention.senderName(in: nil, rosterName: "Best Friend", jidString: jid) == "Best Friend")
        // A stranger has no roster name, and keeps the chat's short title.
        #expect(IncomingAttention.senderName(in: unnamed, rosterName: nil, jidString: jid) == "friend")
        #expect(IncomingAttention.senderName(in: nil, rosterName: nil, jidString: jid) == jid)
    }
}

struct AppStateObserverTests {
    @Test func `the app is visible while it is active or one of its titled windows is on screen`() {
        let menuBarItem = (isTitled: false, isOnScreen: true)
        let hiddenWindow = (isTitled: true, isOnScreen: false)
        let shownWindow = (isTitled: true, isOnScreen: true)

        #expect(AppStateObserver.isAppVisible(isActive: true, windows: []))
        #expect(AppStateObserver.isAppVisible(isActive: false, windows: [menuBarItem, hiddenWindow, shownWindow]))
        // The menu bar item is on screen whenever the menu bar is, and says nothing about the app being looked at.
        #expect(!AppStateObserver.isAppVisible(isActive: false, windows: [menuBarItem, hiddenWindow]))
    }
}
