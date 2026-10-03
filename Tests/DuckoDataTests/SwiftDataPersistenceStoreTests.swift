import Foundation
import Testing
@testable import DuckoCore
@testable import DuckoData
@testable import DuckoXMPP

struct SwiftDataPersistenceStoreTests {
    private func makeStore() throws -> SwiftDataPersistenceStore {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        return SwiftDataPersistenceStore(modelContainer: container)
    }

    private func makeAccount(
        id: UUID = UUID(),
        jid: String = "user@example.com",
        isEnabled: Bool = true,
        connectOnLaunch: Bool = false
    ) -> Account {
        Account(
            id: id,
            jid: BareJID.parse(jid)!,
            isEnabled: isEnabled,
            connectOnLaunch: connectOnLaunch,
            createdAt: Date()
        )
    }

    private func makeContact(
        id: UUID = UUID(),
        accountID: UUID,
        jid: String = "contact@example.com",
        groups: [String] = []
    ) -> Contact {
        Contact(
            id: id,
            accountID: accountID,
            jid: BareJID.parse(jid)!,
            subscription: .none,
            groups: groups,
            isBlocked: false,
            createdAt: Date()
        )
    }

    private func makeConversation(
        id: UUID = UUID(),
        accountID: UUID,
        jid: String = "contact@example.com",
        type: Conversation.ConversationType = .chat
    ) -> Conversation {
        Conversation(
            id: id,
            accountID: accountID,
            jid: BareJID.parse(jid)!,
            type: type,
            isPinned: false,
            isMuted: false,
            unreadCount: 0,
            createdAt: Date()
        )
    }

    // MARK: - Accounts

    struct Accounts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Insert and update share all mutable account fields`() async throws {
            let store = try outer.makeStore()
            var account = outer.makeAccount()
            let createdAt = account.createdAt
            account.displayName = "Imported account"
            account.isEnabled = false
            account.connectOnLaunch = true
            account.host = "xmpp.example.com"
            account.port = 5223
            account.resource = "desktop"
            account.requireTLS = false
            account.rosterVersion = "v1"
            account.certificateFingerprint = "AA:BB"
            account.importedFrom = "Adium"
            try await store.saveAccount(account)

            let inserted = try #require(try await store.fetchAccounts().first)
            expectInsertedAccount(inserted, matches: account)

            account.certificateFingerprint = "CC:DD"
            account.importedFrom = "Other"
            account.createdAt = createdAt.addingTimeInterval(100)
            try await store.saveAccount(account)
            let updated = try #require(try await store.fetchAccounts().first)
            #expect(updated.certificateFingerprint == "CC:DD")
            #expect(updated.importedFrom == "Other")
            #expect(updated.id == account.id)
            #expect(updated.createdAt == createdAt)

            account.displayName = nil
            account.host = nil
            account.port = nil
            account.resource = nil
            account.rosterVersion = nil
            account.certificateFingerprint = nil
            account.importedFrom = nil
            try await store.saveAccount(account)
            let cleared = try #require(try await store.fetchAccounts().first)
            #expect(cleared.displayName == nil)
            #expect(cleared.host == nil)
            #expect(cleared.port == nil)
            #expect(cleared.resource == nil)
            #expect(cleared.rosterVersion == "v1")
            #expect(cleared.certificateFingerprint == nil)
            #expect(cleared.importedFrom == nil)
        }

        private func expectInsertedAccount(_ inserted: Account, matches account: Account) {
            #expect(inserted.id == account.id)
            #expect(inserted.jid == account.jid)
            #expect(inserted.createdAt == account.createdAt)
            #expect(inserted.displayName == account.displayName)
            #expect(inserted.isEnabled == false)
            #expect(inserted.connectOnLaunch == true)
            #expect(inserted.host == account.host)
            #expect(inserted.port == account.port)
            #expect(inserted.resource == account.resource)
            #expect(inserted.requireTLS == false)
            #expect(inserted.rosterVersion == account.rosterVersion)
            #expect(inserted.certificateFingerprint == "AA:BB")
            #expect(inserted.importedFrom == "Adium")
        }

        @Test
        func `Save and fetch account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()

            try await store.saveAccount(account)
            let fetched = try await store.fetchAccounts()

            #expect(fetched.count == 1)
            #expect(fetched.first?.id == account.id)
            #expect(fetched.first?.jid == account.jid)
        }

        @Test
        func `Update existing account`() async throws {
            let store = try outer.makeStore()
            var account = outer.makeAccount()
            try await store.saveAccount(account)

            account.displayName = "Updated"
            account.connectOnLaunch = true
            try await store.saveAccount(account)

            let fetched = try await store.fetchAccounts()
            #expect(fetched.count == 1)
            #expect(fetched.first?.displayName == "Updated")
            #expect(fetched.first?.connectOnLaunch == true)
        }

        @Test
        func `Delete account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            try await store.deleteAccount(account.id)
            let fetched = try await store.fetchAccounts()
            #expect(fetched.isEmpty)
        }

        @Test
        func `Delete account nullifies relationships`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id)
            try await store.upsertContact(contact)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.deleteAccount(account.id)

            // Records no longer associated with the deleted account
            let contacts = try await store.fetchContacts(for: account.id)
            let conversations = try await store.fetchConversations(for: account.id)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)

            // But conversation record still exists (nullified, not cascade-deleted)
            let allConversations = try await store.fetchAllConversations()
            #expect(allConversations.count == 1)
            #expect(allConversations.first?.accountID == nil)
        }
    }

    // MARK: - Contacts

    struct Contacts {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Upsert and fetch contacts by account`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let contact = outer.makeContact(accountID: account.id, jid: "alice@example.com")
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.jid.description == "alice@example.com")
        }

        @Test
        func `Update existing contact`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var contact = outer.makeContact(accountID: account.id)
            try await store.upsertContact(contact)

            contact.name = "Alice"
            contact.subscription = .both
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.name == "Alice")
            #expect(fetched.first?.subscription == .both)
        }

        @Test
        func `Groups array round-trips`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let groups = ["Friends", "Work", "Family"]
            let contact = outer.makeContact(accountID: account.id, groups: groups)
            try await store.upsertContact(contact)

            let fetched = try await store.fetchContacts(for: account.id)
            #expect(fetched.first?.groups == groups)
        }

        @Test
        func `Fetch scoped to account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let contact1 = outer.makeContact(accountID: account1.id, jid: "alice@example.com")
            let contact2 = outer.makeContact(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertContact(contact1)
            try await store.upsertContact(contact2)

            let fetched1 = try await store.fetchContacts(for: account1.id)
            let fetched2 = try await store.fetchContacts(for: account2.id)
            #expect(fetched1.count == 1)
            #expect(fetched1.first?.jid.description == "alice@example.com")
            #expect(fetched2.count == 1)
            #expect(fetched2.first?.jid.description == "bob@example.com")
        }
    }

    // MARK: - Conversations

    struct Conversations {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test(arguments: [false, true])
        func `Insert and update share mutable conversation fields`(imported: Bool) async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)
            var conversation = outer.makeConversation(accountID: account.id, type: .groupchat)
            let createdAt = conversation.createdAt
            if imported { conversation.accountID = nil }
            conversation.importSourceJID = "archive@example.com"
            conversation.displayName = "Room"
            conversation.isPinned = true
            conversation.isMuted = true
            conversation.lastMessageDate = createdAt
            conversation.lastMessagePreview = "Preview"
            conversation.unreadCount = 3
            conversation.roomSubject = "Subject"
            conversation.roomNickname = "Self"
            conversation.encryptionEnabled = true
            conversation.encryptionOptedOut = true
            conversation.occupantNickname = "Other"
            conversation.lastReadTimestamp = createdAt
            try await store.upsertConversation(conversation)

            let inserted = try #require(try await store.fetchAllConversations().first)
            expectInsertedConversation(inserted, matches: conversation)

            conversation.accountID = account.id
            conversation.createdAt = createdAt.addingTimeInterval(100)
            conversation.occupantNickname = "Renamed"
            try await store.upsertConversation(conversation)
            let updated = try #require(try await store.fetchConversations(for: account.id).first)
            #expect(updated.accountID == account.id)
            #expect(updated.id == conversation.id)
            #expect(updated.createdAt == createdAt)
            #expect(updated.occupantNickname == "Renamed")
            #expect(updated.encryptionEnabled == true)

            conversation.accountID = nil
            conversation.importSourceJID = nil
            conversation.displayName = nil
            conversation.lastMessageDate = nil
            conversation.lastMessagePreview = nil
            conversation.roomSubject = nil
            conversation.roomNickname = nil
            conversation.encryptionEnabled = false
            conversation.encryptionOptedOut = false
            conversation.occupantNickname = nil
            conversation.lastReadTimestamp = nil
            try await store.upsertConversation(conversation)
            let cleared = try #require(try await store.fetchAllConversations().first)
            expectClearedConversation(cleared)
        }

        private func expectClearedConversation(_ cleared: Conversation) {
            #expect(cleared.accountID == nil)
            #expect(cleared.importSourceJID == nil)
            #expect(cleared.displayName == nil)
            #expect(cleared.lastMessageDate == nil)
            #expect(cleared.lastMessagePreview == nil)
            #expect(cleared.roomSubject == nil)
            #expect(cleared.roomNickname == nil)
            #expect(cleared.encryptionEnabled == false)
            #expect(cleared.encryptionOptedOut == false)
            #expect(cleared.occupantNickname == nil)
            #expect(cleared.lastReadTimestamp == nil)
        }

        private func expectInsertedConversation(_ inserted: Conversation, matches conversation: Conversation) {
            #expect(inserted.id == conversation.id)
            #expect(inserted.createdAt == conversation.createdAt)
            #expect(inserted.jid == conversation.jid)
            #expect(inserted.type == .groupchat)
            #expect(inserted.accountID == conversation.accountID)
            #expect(inserted.importSourceJID == conversation.importSourceJID)
            #expect(inserted.displayName == conversation.displayName)
            #expect(inserted.isPinned == true)
            #expect(inserted.isMuted == true)
            #expect(inserted.lastMessageDate == conversation.createdAt)
            #expect(inserted.lastMessagePreview == "Preview")
            #expect(inserted.unreadCount == 3)
            #expect(inserted.roomSubject == "Subject")
            #expect(inserted.roomNickname == "Self")
            #expect(inserted.encryptionEnabled == true)
            #expect(inserted.encryptionOptedOut == true)
            #expect(inserted.occupantNickname == "Other")
            #expect(inserted.lastReadTimestamp == conversation.createdAt)
        }

        @Test
        func `Updating a conversation changes the stored row, not the caller's older copy of it`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)
            var conversation = outer.makeConversation(accountID: account.id)
            conversation.unreadCount = 1
            try await store.upsertConversation(conversation)
            // What another writer stored after the caller last read the row.
            conversation.encryptionEnabled = true
            conversation.isMuted = true
            try await store.upsertConversation(conversation)

            let date = conversation.createdAt.addingTimeInterval(60)
            let updated = try await store.updateConversation(conversation.id) {
                $0.lastMessageDate = date
                $0.lastMessagePreview = "Hello"
                $0.unreadCount += 1
            }

            let stored = try #require(try await store.fetchConversations(for: account.id).first)
            #expect(updated?.unreadCount == 2)
            #expect(stored.lastMessageDate == date)
            #expect(stored.lastMessagePreview == "Hello")
            #expect(stored.unreadCount == 2)
            #expect(stored.encryptionEnabled)
            #expect(stored.isMuted)
        }

        @Test
        func `Updating a conversation can move it to another account`() async throws {
            let store = try outer.makeStore()
            let first = outer.makeAccount()
            let second = outer.makeAccount(jid: "other@example.com")
            try await store.saveAccount(first)
            try await store.saveAccount(second)
            let conversation = outer.makeConversation(accountID: first.id)
            try await store.upsertConversation(conversation)

            let secondID = second.id
            try await store.updateConversation(conversation.id) { $0.accountID = secondID }

            #expect(try await store.fetchConversations(for: first.id).isEmpty)
            #expect(try await store.fetchConversations(for: secondID).map(\.id) == [conversation.id])
        }

        @Test
        func `Missing parent rejects insertion but existing relationship reconciliation stays permissive`() async throws {
            let store = try outer.makeStore()
            var conversation = outer.makeConversation(accountID: UUID())
            await #expect(throws: PersistenceStoreError.self) {
                try await store.upsertConversation(conversation)
            }
            #expect(try await store.fetchAllConversations().isEmpty)

            conversation.accountID = nil
            try await store.upsertConversation(conversation)
            conversation.accountID = UUID()
            try await store.upsertConversation(conversation)
            let updated = try #require(try await store.fetchAllConversations().first)
            #expect(updated.id == conversation.id)
            #expect(updated.accountID == nil)
        }

        @Test
        func `Upsert and fetch conversations`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.count == 1)
            #expect(fetched.first?.id == conversation.id)
        }

        @Test(arguments: [
            Conversation.ConversationType.chat,
            Conversation.ConversationType.groupchat
        ])
        func `Conversation type round-trips`(type: Conversation.ConversationType) async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id, type: type)
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.type == type)
        }

        @Test
        func `Last message date and preview update`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            let now = Date()
            conversation.lastMessageDate = now
            conversation.lastMessagePreview = "Hello!"
            try await store.upsertConversation(conversation)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.lastMessagePreview == "Hello!")
        }

        @Test
        func `Fetch single conversation by JID and type`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let chat = outer.makeConversation(accountID: account.id, jid: "alice@example.com", type: .chat)
            let room = outer.makeConversation(accountID: account.id, jid: "room@conference.example.com", type: .groupchat)
            try await store.upsertConversation(chat)
            try await store.upsertConversation(room)

            let fetchedRoom = try await store.fetchConversation(jid: "room@conference.example.com", type: .groupchat, accountID: account.id, importSourceJID: nil)
            #expect(fetchedRoom?.id == room.id)

            let fetchedChat = try await store.fetchConversation(jid: "alice@example.com", type: .chat, accountID: account.id, importSourceJID: nil)
            #expect(fetchedChat?.id == chat.id)
        }

        @Test
        func `Fetch conversation returns nil when not found`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let result = try await store.fetchConversation(jid: "nobody@example.com", type: .chat, accountID: account.id, importSourceJID: nil)
            #expect(result == nil)
        }

        @Test
        func `Mark conversation read resets unread count`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            var conversation = outer.makeConversation(accountID: account.id)
            conversation.unreadCount = 5
            try await store.upsertConversation(conversation)

            try await store.markConversationRead(conversation.id)

            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.first?.unreadCount == 0)
            #expect(fetched.first?.lastReadTimestamp != nil)
        }

        @Test
        func `Delete conversation removes only the target conversation`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let target = outer.makeConversation(accountID: account.id, jid: "alice@example.com")
            let other = outer.makeConversation(accountID: account.id, jid: "bob@example.com")
            try await store.upsertConversation(target)
            try await store.upsertConversation(other)

            try await store.deleteConversation(target.id)

            let remaining = try await store.fetchConversations(for: account.id)
            #expect(remaining.count == 1)
            #expect(remaining.first?.id == other.id)
        }

        @Test
        func `Delete conversation is a no-op for an unknown id`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.deleteConversation(UUID())

            let remaining = try await store.fetchConversations(for: account.id)
            #expect(remaining.count == 1)
            #expect(remaining.first?.id == conversation.id)
        }

        @Test
        func `Updating a conversation does not insert a missing row`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            // A conversation that was never persisted (or was deleted) must not be
            // recreated — the guard against resurrecting a destroyed room.
            let ghost = outer.makeConversation(accountID: account.id)
            let updated = try await store.updateConversation(ghost.id) { $0.unreadCount = 7 }

            #expect(updated == nil)
            let fetched = try await store.fetchConversations(for: account.id)
            #expect(fetched.isEmpty)
        }
    }

    // MARK: - Account Cleanup

    struct AccountCleanup {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Unlink conversations restores importSourceJID`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.unlinkConversations(for: account.id, restoreImportSourceJID: "user@example.com")

            let linked = try await store.fetchConversations(for: account.id)
            #expect(linked.isEmpty)

            let all = try await store.fetchAllConversations()
            #expect(all.count == 1)
            #expect(all.first?.accountID == nil)
            #expect(all.first?.importSourceJID == "user@example.com")
        }

        @Test
        func `Unlink then re-link round trip`() async throws {
            let store = try outer.makeStore()
            let account = outer.makeAccount()
            try await store.saveAccount(account)

            let conversation = outer.makeConversation(accountID: account.id)
            try await store.upsertConversation(conversation)

            try await store.unlinkConversations(for: account.id, restoreImportSourceJID: "user@example.com")

            // Verify conversations are discoverable by importSourceJID
            let imported = try await store.fetchConversations(importSourceJID: "user@example.com")
            #expect(imported.count == 1)
            #expect(imported.first?.id == conversation.id)
        }

        @Test
        func `Delete conversations removes only target account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let conv1 = outer.makeConversation(accountID: account1.id, jid: "alice@example.com")
            let conv2 = outer.makeConversation(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertConversation(conv1)
            try await store.upsertConversation(conv2)

            try await store.deleteConversations(for: account1.id)

            let remaining = try await store.fetchAllConversations()
            #expect(remaining.count == 1)
            #expect(remaining.first?.id == conv2.id)
        }

        @Test
        func `Delete contacts removes only target account`() async throws {
            let store = try outer.makeStore()
            let account1 = outer.makeAccount(jid: "user1@example.com")
            let account2 = outer.makeAccount(jid: "user2@example.com")
            try await store.saveAccount(account1)
            try await store.saveAccount(account2)

            let contact1 = outer.makeContact(accountID: account1.id, jid: "alice@example.com")
            let contact2 = outer.makeContact(accountID: account2.id, jid: "bob@example.com")
            try await store.upsertContact(contact1)
            try await store.upsertContact(contact2)

            try await store.deleteContacts(for: account1.id)

            let remaining1 = try await store.fetchContacts(for: account1.id)
            let remaining2 = try await store.fetchContacts(for: account2.id)
            #expect(remaining1.isEmpty)
            #expect(remaining2.count == 1)
            #expect(remaining2.first?.id == contact2.id)
        }
    }

    // MARK: - Edge Cases

    struct EdgeCases {
        private let outer = SwiftDataPersistenceStoreTests()

        @Test
        func `Fetch on empty store returns empty array`() async throws {
            let store = try outer.makeStore()
            let accounts = try await store.fetchAccounts()
            let contacts = try await store.fetchContacts(for: UUID())
            let conversations = try await store.fetchConversations(for: UUID())
            #expect(accounts.isEmpty)
            #expect(contacts.isEmpty)
            #expect(conversations.isEmpty)
        }

        @Test
        func `Delete nonexistent account is no-op`() async throws {
            let store = try outer.makeStore()
            try await store.deleteAccount(UUID())
        }
    }
}
