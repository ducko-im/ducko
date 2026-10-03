import Foundation

public protocol PersistenceStore: Sendable {
    // MARK: - Accounts

    func fetchAccounts() async throws -> [Account]
    func saveAccount(_ account: Account) async throws
    func deleteAccount(_ id: UUID) async throws

    // MARK: - Contacts

    func fetchContacts(for accountID: UUID) async throws -> [Contact]
    func upsertContact(_ contact: Contact) async throws
    func deleteContact(_ id: UUID) async throws
    func applyRosterMutation(_ mutation: RosterMutation) async throws -> [Contact]
    @discardableResult
    func updateContactIfExists(_ id: UUID, accountID: UUID, update: ContactMetadataUpdate) async throws -> Bool

    // MARK: - Conversations

    func fetchConversations(for accountID: UUID) async throws -> [Conversation]
    func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) async throws -> Conversation?
    func fetchConversations(importSourceJID: String) async throws -> [Conversation]
    func upsertConversation(_ conversation: Conversation) async throws
    /// Changes an existing conversation's row and returns the conversation as stored afterwards, or `nil` when no
    /// row with that ID exists. `change` is applied to the row as it is stored, not to a copy the caller read
    /// earlier, so it writes only what it sets and cannot undo what another writer stored meanwhile. Unlike
    /// `upsertConversation`, this never inserts, so stale in-flight async work can't resurrect a conversation deleted
    /// while it was awaiting.
    @discardableResult
    func updateConversation(_ conversationID: UUID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation?
    func fetchAllConversations() async throws -> [Conversation]
    func markConversationRead(_ conversationID: UUID) async throws
    func deleteConversation(_ conversationID: UUID) async throws

    // MARK: - Account Cleanup

    func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) async throws
    func deleteConversations(for accountID: UUID) async throws
    func deleteContacts(for accountID: UUID) async throws

    // MARK: - Link Previews

    func fetchLinkPreview(for url: String) async throws -> LinkPreview?
    func upsertLinkPreview(_ preview: LinkPreview) async throws
}
