import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoXMPP

/// Sending, correcting, retracting and moderating in a conversation decide from the conversation as stored, not from
/// the copy the caller holds.
@MainActor
struct ChatServiceConversationSendTests {
    enum Operation: CaseIterable {
        case send, correct, retract, moderate

        /// The kind of conversation the operation is run in where any would do: a moderation is run only in a room.
        var kind: ConversationKind {
            switch self {
            case .send, .correct, .retract: .contact
            case .moderate: .room
            }
        }

        func run(in conversation: Conversation, own: ChatMessage, chatService: ChatService, accountID: UUID) async throws {
            switch self {
            case .send: try await chatService.sendMessage("hi", in: conversation, accountID: accountID)
            case .correct: try await chatService.sendCorrection(of: own, newBody: "fixed", in: conversation, accountID: accountID)
            case .retract: try await chatService.retractMessage(own, in: conversation, accountID: accountID)
            case .moderate: try await chatService.moderateMessage(serverID: "t1", in: conversation, reason: nil, accountID: accountID)
            }
        }
    }

    @Test(arguments: Operation.allCases, [UUID?.some(UUID()), nil])
    func `Nothing is sent in a conversation of another account or of none`(_ operation: Operation, owner: UUID?) async throws {
        let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
        var conversation = operation.kind.conversation(accountID: harness.accountID)
        conversation.accountID = owner
        try await harness.store.upsertConversation(conversation)
        let own = operation.kind.message(in: conversation, stanzaID: "m1", serverID: "t1", body: "Mine", isOutgoing: true)
        await harness.transcripts.addMessage(own)

        let error = await #expect(throws: ChatService.ChatServiceError.self) {
            try await operation.run(in: conversation, own: own, chatService: harness.chatService, accountID: harness.accountID)
        }
        let isNotInAccount = if case .conversationNotInAccount? = error { true } else { false }
        #expect(isNotInAccount)

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") || $0.contains(XMPPNamespaces.messageModerate) })
        #expect(await harness.transcripts.messages.count == 1)
        #expect(await harness.transcripts.amendments.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// The copy can predate the user switching encryption on, and must not send in the clear.
    @Test(arguments: [ConversationKind.contact, .room])
    func `A send follows the stored encryption switch, not the copy passed in`(kind: ConversationKind) async throws {
        let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
        let stale = kind.conversation(accountID: harness.accountID)
        var stored = stale
        stored.encryptionEnabled = true
        try await harness.store.upsertConversation(stored)

        let error = await #expect(throws: ChatService.ChatServiceError.self) {
            try await harness.chatService.sendMessage("secret", in: stale, accountID: harness.accountID)
        }
        let isOMEMOUnavailable = if case .omemoServiceUnavailable? = error { true } else { false }
        #expect(isOMEMOUnavailable)

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.contains("secret") })
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Switching encryption off later must not show the server which encrypted message was changed or taken back.
    @Test(arguments: [Operation.correct, .retract], ConversationKind.allCases)
    func `The correction or retraction of an encrypted message is not sent in the clear`(_ operation: Operation, kind: ConversationKind) async throws {
        let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
        let conversation = kind.conversation(accountID: harness.accountID)
        try await harness.store.upsertConversation(conversation)
        let own = kind.message(in: conversation, stanzaID: "m1", serverID: "t1", body: "secret", isOutgoing: true, isEncrypted: true)
        await harness.transcripts.addMessage(own)

        let error = await #expect(throws: ChatService.ChatServiceError.self) {
            try await operation.run(in: conversation, own: own, chatService: harness.chatService, accountID: harness.accountID)
        }
        let isRefused = if case .encryptionFailed? = error {
            kind == .privateChat
        } else if case .omemoServiceUnavailable? = error {
            kind != .privateChat
        } else {
            false
        }
        #expect(isRefused)

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        #expect(await harness.transcripts.amendments.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    /// Nothing sent in a room's private chat is encrypted, so encryption switched on there sends nothing.
    @Test(arguments: [Operation.send, .correct])
    func `A room's private chat with encryption switched on sends nothing`(_ operation: Operation) async throws {
        let harness = try await makeFilterHarness(modules: [MUCModule()], filters: [])
        let conversation = ConversationKind.privateChat.conversation(accountID: harness.accountID, encryptionEnabled: true)
        try await harness.store.upsertConversation(conversation)
        let own = ConversationKind.privateChat.message(in: conversation, stanzaID: "m1", body: "Mine", isOutgoing: true)
        await harness.transcripts.addMessage(own)

        let error = await #expect(throws: ChatService.ChatServiceError.self) {
            try await operation.run(in: conversation, own: own, chatService: harness.chatService, accountID: harness.accountID)
        }
        let isEncryptionFailure = if case .encryptionFailed? = error { true } else { false }
        #expect(isEncryptionFailure)

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        #expect(await harness.transcripts.messages.count == 1)
        #expect(await harness.transcripts.amendments.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }

    @Test(arguments: ConversationKind.allCases)
    func `A reply to a message of another conversation is not sent`(kind: ConversationKind) async throws {
        let harness = try await makeFilterHarness(modules: [ChatModule(), MUCModule()], filters: [])
        let conversation = kind.conversation(accountID: harness.accountID)
        try await harness.store.upsertConversation(conversation)
        let elsewhere = kind.conversation(accountID: harness.accountID)
        let quoted = kind.message(in: elsewhere, stanzaID: "q1", serverID: "t1", body: "Elsewhere", isOutgoing: false)

        let error = await #expect(throws: ChatService.ChatServiceError.self) {
            try await harness.chatService.sendMessage("ok", in: conversation, replyingTo: quoted, accountID: harness.accountID)
        }
        let isNotInConversation = if case .messageNotInConversation? = error { true } else { false }
        #expect(isNotInConversation)

        let sent = await harness.transport.sentBytes.map { String(decoding: $0, as: UTF8.self) }
        #expect(!sent.contains { $0.hasPrefix("<message") })
        #expect(await harness.transcripts.messages.isEmpty)
        await harness.accountService.disconnect(accountID: harness.accountID)
    }
}
