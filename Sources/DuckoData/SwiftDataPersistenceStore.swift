import DuckoCore
import DuckoXMPP
import Foundation
import SwiftData

enum PersistenceStoreError: Error {
    case parentNotFound(String)
}

@ModelActor
public actor SwiftDataPersistenceStore: PersistenceStore {
    var beforeRosterSaveForTesting: (@Sendable () throws -> Void)?

    func setBeforeRosterSaveForTesting(_ hook: (@Sendable () throws -> Void)?) {
        beforeRosterSaveForTesting = hook
    }

    // MARK: - Accounts

    public func fetchAccounts() throws -> [Account] {
        let descriptor = FetchDescriptor<AccountRecord>(sortBy: [SortDescriptor(\.createdAt)])
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func saveAccount(_ account: Account) throws {
        let accountID = account.id
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate { $0.id == accountID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: account)
        } else {
            let record = AccountRecord(
                id: account.id,
                jid: account.jid.description,
                createdAt: account.createdAt
            )
            record.update(from: account)
            record.rosterVersion = account.rosterVersion
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func deleteAccount(_ id: UUID) throws {
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    // MARK: - Contacts

    public func fetchContacts(for accountID: UUID) throws -> [Contact] {
        let descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.account?.id == accountID },
            sortBy: [SortDescriptor(\.jid)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func upsertContact(_ contact: Contact) throws {
        let contactID = contact.id
        var descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.id == contactID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: contact)
        } else {
            let accountID = contact.accountID
            var accountDescriptor = FetchDescriptor<AccountRecord>(
                predicate: #Predicate { $0.id == accountID }
            )
            accountDescriptor.fetchLimit = 1
            guard let accountRecord = try modelContext.fetch(accountDescriptor).first else {
                throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
            }

            let record = ContactRecord(
                id: contact.id,
                jid: contact.jid.description,
                name: contact.name,
                localAlias: contact.localAlias,
                subscription: contact.subscription.rawValue,
                ask: contact.ask,
                groups: contact.groups,
                avatarHash: contact.avatarHash,
                avatarData: contact.avatarData,
                isBlocked: contact.isBlocked,
                account: accountRecord,
                lastSeen: contact.lastSeen,
                createdAt: contact.createdAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    public func deleteContact(_ id: UUID) throws {
        var descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
            try modelContext.save()
        }
    }

    public func applyRosterMutation(_ mutation: RosterMutation) throws -> [Contact] {
        try Task.checkCancellation()
        let accountID = mutation.accountID
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == accountID })
        descriptor.fetchLimit = 1
        guard let account = try modelContext.fetch(descriptor).first else {
            throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
        }
        do {
            let records = try modelContext.fetch(FetchDescriptor<ContactRecord>(predicate: #Predicate { $0.account?.id == accountID }))
            let items: [RosterMutation.Item]
            switch mutation.contents {
            case let .snapshot(snapshot):
                items = snapshot
                let retainedJIDs = Set(snapshot.filter { !$0.isRemoval }.map(\.jid.description))
                for record in records where !retainedJIDs.contains(record.jid) {
                    modelContext.delete(record)
                }
            case let .delta(item): items = [item]
            }
            for item in items {
                let existing = records.first { $0.jid == item.jid.description }
                if item.isRemoval {
                    if let existing, !existing.isDeleted { modelContext.delete(existing) }
                } else if let existing {
                    existing.update(from: item.merging(into: existing.toDomain(), accountID: accountID))
                } else {
                    let contact = item.merging(into: nil, accountID: accountID)
                    let record = ContactRecord(id: contact.id, jid: contact.jid.description, subscription: contact.subscription.rawValue, account: account, createdAt: contact.createdAt)
                    record.update(from: contact)
                    modelContext.insert(record)
                }
            }
            account.rosterVersion = mutation.version
            let contacts = try fetchContacts(for: accountID)
            try beforeRosterSaveForTesting?()
            try modelContext.save()
            return contacts
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    @discardableResult
    public func updateContactIfExists(_ id: UUID, accountID: UUID, update: ContactMetadataUpdate) throws -> Bool {
        try Task.checkCancellation()
        var descriptor = FetchDescriptor<ContactRecord>(predicate: #Predicate { $0.id == id && $0.account?.id == accountID })
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first, var contact = record.toDomain() else { return false }
        update.apply(to: &contact)
        do {
            record.update(from: contact)
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    // MARK: - Conversations

    public func fetchConversations(for accountID: UUID) throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.account?.id == accountID },
            sortBy: [SortDescriptor(\.lastMessageDate, order: .reverse)]
        )
        let records: [ConversationRecord] = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func fetchConversation(jid: String, type: Conversation.ConversationType, accountID: UUID?, importSourceJID: String?) throws -> Conversation? {
        let jidString = jid
        let typeString = type.rawValue
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.jid == jidString && $0.type == typeString && $0.account?.id == accountID && $0.importSourceJID == importSourceJID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func fetchConversations(importSourceJID: String) throws -> [Conversation] {
        let sourceJID = importSourceJID
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.importSourceJID == sourceJID }
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toDomain() }
    }

    public func upsertConversation(_ conversation: Conversation) throws {
        let conversationID = conversation.id
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            try applyUpdate(to: existing, from: conversation)
        } else {
            var accountRecord: AccountRecord?
            if let accountID = conversation.accountID {
                var accountDescriptor = FetchDescriptor<AccountRecord>(
                    predicate: #Predicate { $0.id == accountID }
                )
                accountDescriptor.fetchLimit = 1
                guard let record = try modelContext.fetch(accountDescriptor).first else {
                    throw PersistenceStoreError.parentNotFound("AccountRecord(\(accountID))")
                }
                accountRecord = record
            }

            let record = ConversationRecord(
                id: conversation.id,
                jid: conversation.jid.description,
                account: accountRecord,
                createdAt: conversation.createdAt
            )
            record.update(from: conversation)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    @discardableResult
    public func updateConversation(_ conversationID: UUID, _ change: @Sendable (inout Conversation) -> Void) throws -> Conversation? {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1
        guard let existing = try modelContext.fetch(descriptor).first, var conversation = existing.toDomain() else { return nil }

        change(&conversation)
        try applyUpdate(to: existing, from: conversation)
        try modelContext.save()
        return conversation
    }

    /// Applies `conversation`'s fields onto an existing record and reconciles its account
    /// relationship (e.g. auto-linking an imported conversation to a now-present account).
    private func applyUpdate(to existing: ConversationRecord, from conversation: Conversation) throws {
        existing.update(from: conversation)
        guard existing.account?.id != conversation.accountID else { return }
        if let accountID = conversation.accountID {
            var accountDescriptor = FetchDescriptor<AccountRecord>(
                predicate: #Predicate { $0.id == accountID }
            )
            accountDescriptor.fetchLimit = 1
            existing.account = try modelContext.fetch(accountDescriptor).first
        } else {
            existing.account = nil
        }
    }

    public func fetchAllConversations() throws -> [Conversation] {
        let descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.lastMessageDate, order: .reverse)]
        )
        let records = try modelContext.fetch(descriptor)
        return records.compactMap { $0.toDomain() }
    }

    public func markConversationRead(_ conversationID: UUID) throws {
        var descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            record.unreadCount = 0
            record.lastReadTimestamp = Date()
            try modelContext.save()
        }
    }

    public func deleteConversation(_ conversationID: UUID) throws {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.id == conversationID }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    // MARK: - Account Cleanup

    public func unlinkConversations(for accountID: UUID, restoreImportSourceJID: String) throws {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.account?.id == accountID }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            record.account = nil
            record.importSourceJID = restoreImportSourceJID
        }
        try modelContext.save()
    }

    public func deleteConversations(for accountID: UUID) throws {
        let descriptor = FetchDescriptor<ConversationRecord>(
            predicate: #Predicate { $0.account?.id == accountID }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    public func deleteContacts(for accountID: UUID) throws {
        let descriptor = FetchDescriptor<ContactRecord>(
            predicate: #Predicate { $0.account?.id == accountID }
        )
        let records = try modelContext.fetch(descriptor)
        for record in records {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    // MARK: - Link Previews

    public func fetchLinkPreview(for url: String) throws -> LinkPreview? {
        var descriptor = FetchDescriptor<LinkPreviewRecord>(
            predicate: #Predicate { $0.url == url }
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.toDomain()
    }

    public func upsertLinkPreview(_ preview: LinkPreview) throws {
        let previewURL = preview.url
        var descriptor = FetchDescriptor<LinkPreviewRecord>(
            predicate: #Predicate { $0.url == previewURL }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
            existing.update(from: preview)
        } else {
            let record = LinkPreviewRecord(
                url: preview.url,
                title: preview.title,
                descriptionText: preview.descriptionText,
                imageURL: preview.imageURL,
                siteName: preview.siteName,
                fetchedAt: preview.fetchedAt
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }
}
