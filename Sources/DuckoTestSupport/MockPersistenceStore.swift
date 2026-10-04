import DuckoCore
import Foundation

public actor MockPersistenceStore: PersistenceStore {
    public var accounts: [Account] = []
    private var fetchAccountsError: Error?

    public func setFetchAccountsError(_ error: Error?) {
        fetchAccountsError = error
    }

    public var contacts: [Contact] = []
    public var conversations: [Conversation] = []
    public var linkPreviews: [LinkPreview] = []
    /// Test seam: when set, `fetchConversations(for:)` throws this instead of returning, so the
    /// account-aware cache's failed-fetch-leaves-the-slot-intact path is exercisable.
    public var fetchConversationsError: Error?
    /// Test seam: when installed, `fetchContacts(for:)` signals `entered` (the store read is in flight)
    /// and then awaits `release` before returning, so a test can interleave a teardown between the read
    /// and the caller's cache write. Nil → no gating.
    private var fetchContactsGateEntered: AsyncSemaphore?
    private var fetchContactsGateRelease: AsyncSemaphore?

    private var conversationWriteGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var markConversationReadGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var fetchAccountsGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var contactCaptureGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var contactWriteGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var rosterApplyGate: (entered: AsyncSemaphore, release: AsyncSemaphore)?
    private var rosterApplyFailures = 0
    public private(set) var rosterMutations: [RosterMutation] = []

    public enum RosterFailure: Error { case injected, missingAccount }

    public func installContactCaptureGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        contactCaptureGate = (entered, release)
    }

    public func installContactWriteGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        contactWriteGate = (entered, release)
    }

    public func installRosterApplyGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        rosterApplyGate = (entered, release)
    }

    public func failNextRosterApplications(_ count: Int = 1) {
        rosterApplyFailures = count
    }

    public init() {}

    /// Holds the next `fetchAccounts` until `release` is signaled, signaling `entered` once it is held.
    public func installFetchAccountsGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        fetchAccountsGate = (entered, release)
    }

    public func installConversationWriteGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        conversationWriteGate = (entered, release)
    }

    /// Holds the next `markConversationRead` before it writes, signaling `entered` once it is held.
    public func installMarkConversationReadGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        markConversationReadGate = (entered, release)
    }

    private func awaitConversationWriteGate() async {
        guard let gate = conversationWriteGate else { return }
        conversationWriteGate = nil
        await gate.entered.signal()
        await gate.release.wait()
    }

    public func installFetchContactsGate(entered: AsyncSemaphore, release: AsyncSemaphore) {
        fetchContactsGateEntered = entered
        fetchContactsGateRelease = release
    }

    public func clearFetchContactsGate() {
        fetchContactsGateEntered = nil
        fetchContactsGateRelease = nil
    }

    public func setFetchConversationsError(_ error: Error?) {
        fetchConversationsError = error
    }

    public func addAccount(_ account: Account) {
        accounts.append(account)
    }

    public func addConversation(_ conversation: Conversation) {
        conversations.append(conversation)
    }

    // MARK: - Accounts

    public func fetchAccounts() async throws -> [Account] {
        if let gate = fetchAccountsGate {
            fetchAccountsGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        if let fetchAccountsError { throw fetchAccountsError }
        return accounts
    }

    public func saveAccount(_ account: Account) async throws {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let version = accounts[index].rosterVersion
            accounts[index] = account
            accounts[index].rosterVersion = version
        } else {
            accounts.append(account)
        }
    }

    public func deleteAccount(_ id: UUID) async throws {
        accounts.removeAll { $0.id == id }
    }

    // MARK: - Contacts

    public func fetchContacts(for accountID: UUID) async throws -> [Contact] {
        if let entered = fetchContactsGateEntered, let release = fetchContactsGateRelease {
            await entered.signal()
            await release.wait()
        }
        let result = contacts.filter { $0.accountID == accountID }
        if let gate = contactCaptureGate {
            contactCaptureGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        return result
    }

    public func upsertContact(_ contact: Contact) async throws {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
    }

    public func deleteContact(_ id: UUID) async throws {
        contacts.removeAll { $0.id == id }
    }

    public func applyRosterMutation(_ mutation: RosterMutation) async throws -> [Contact] {
        if let gate = rosterApplyGate {
            rosterApplyGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        try Task.checkCancellation()
        guard let accountIndex = accounts.firstIndex(where: { $0.id == mutation.accountID }) else {
            throw RosterFailure.missingAccount
        }
        rosterMutations.append(mutation)
        if rosterApplyFailures > 0 {
            rosterApplyFailures -= 1
            throw RosterFailure.injected
        }
        let items: [RosterMutation.Item]
        switch mutation.contents {
        case let .snapshot(snapshot):
            items = snapshot
            let retained = Set(snapshot.filter { !$0.isRemoval }.map(\.jid))
            contacts.removeAll { $0.accountID == mutation.accountID && !retained.contains($0.jid) }
        case let .delta(item): items = [item]
        }
        for item in items {
            let index = contacts.firstIndex { $0.accountID == mutation.accountID && $0.jid == item.jid }
            if item.isRemoval {
                if let index { contacts.remove(at: index) }
            } else if let index {
                contacts[index] = item.merging(into: contacts[index], accountID: mutation.accountID)
            } else {
                contacts.append(item.merging(into: nil, accountID: mutation.accountID))
            }
        }
        accounts[accountIndex].rosterVersion = mutation.version
        return contacts.filter { $0.accountID == mutation.accountID }
    }

    @discardableResult
    public func updateContactIfExists(_ id: UUID, accountID: UUID, update: ContactMetadataUpdate) async throws -> Bool {
        if let gate = contactWriteGate {
            contactWriteGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        try Task.checkCancellation()
        guard let index = contacts.firstIndex(where: { $0.id == id && $0.accountID == accountID }) else { return false }
        update.apply(to: &contacts[index])
        return true
    }

    // MARK: - Conversations

    public func fetchConversations(for accountID: UUID) async throws -> [Conversation] {
        if let fetchConversationsError { throw fetchConversationsError }
        return conversations.filter { $0.accountID == accountID }
    }

    public func fetchConversations(importSourceJID: String) async throws -> [Conversation] {
        conversations.filter { $0.importSourceJID == importSourceJID }
    }

    public func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) async throws -> Conversation? {
        conversations.first { $0.jid.description == jid && $0.type == type && $0.accountID == accountID && $0.importSourceJID == importSourceJID }
    }

    public func upsertConversation(_ conversation: Conversation) async throws {
        await awaitConversationWriteGate()
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
    }

    @discardableResult
    public func updateConversation(_ conversationID: UUID, _ change: @Sendable (inout Conversation) -> Void) async throws -> Conversation? {
        await awaitConversationWriteGate()
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return nil }
        change(&conversations[index])
        return conversations[index]
    }

    public func fetchAllConversations() async throws -> [Conversation] {
        conversations
    }

    public func markConversationRead(_ conversationID: UUID) async throws {
        if let gate = markConversationReadGate {
            markConversationReadGate = nil
            await gate.entered.signal()
            await gate.release.wait()
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].unreadCount = 0
        conversations[index].lastReadTimestamp = Date()
    }

    public func deleteConversation(_ conversationID: UUID) async throws {
        conversations.removeAll { $0.id == conversationID }
    }

    // MARK: - Account Cleanup

    public func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) async throws {
        for index in conversations.indices where conversations[index].accountID == accountID {
            conversations[index].accountID = nil
            conversations[index].importSourceJID = restoreImportSourceJID
        }
    }

    public func deleteConversations(for accountID: UUID) async throws {
        conversations.removeAll { $0.accountID == accountID }
    }

    public func deleteContacts(for accountID: UUID) async throws {
        contacts.removeAll { $0.accountID == accountID }
    }

    // MARK: - Link Previews

    public func fetchLinkPreview(for url: String) async throws -> LinkPreview? {
        linkPreviews.first { $0.url == url }
    }

    public func upsertLinkPreview(_ preview: LinkPreview) async throws {
        if let index = linkPreviews.firstIndex(where: { $0.url == preview.url }) {
            linkPreviews[index] = preview
        } else {
            linkPreviews.append(preview)
        }
    }
}
