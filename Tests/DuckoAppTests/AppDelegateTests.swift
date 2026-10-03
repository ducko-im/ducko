import DuckoCore
import Foundation
import Testing
@testable import DuckoApp

// MARK: - In-test stubs

/// Empty `PersistenceStore` for tests that exercise `AccountService`'s
/// lifecycle without persisted state. Every fetch returns empty; every
/// mutator is a no-op. Throwing/in-memory stubs aren't shared from
/// `DuckoCoreTests` because that target is not visible here.
private struct EmptyPersistenceStore: PersistenceStore {
    func applyRosterMutation(_: RosterMutation) async throws -> [Contact] {
        []
    }

    func updateContactIfExists(_: UUID, accountID _: UUID, update _: ContactMetadataUpdate) async throws -> Bool {
        false
    }

    func fetchAccounts() async throws -> [Account] {
        []
    }

    func saveAccount(_: Account) async throws {}
    func deleteAccount(_: UUID) async throws {}
    func fetchContacts(for _: UUID) async throws -> [Contact] {
        []
    }

    func upsertContact(_: Contact) async throws {}
    func deleteContact(_: UUID) async throws {}
    func fetchConversations(for _: UUID) async throws -> [Conversation] {
        []
    }

    func fetchConversation(jid _: String, type _: Conversation.ConversationType, accountID _: UUID?, importSourceJID _: String?) async throws -> Conversation? {
        nil
    }

    func fetchConversations(importSourceJID _: String) async throws -> [Conversation] {
        []
    }

    func upsertConversation(_: Conversation) async throws {}
    @discardableResult
    func updateConversation(_: UUID, _: @Sendable (inout Conversation) -> Void) async throws -> Conversation? {
        nil
    }

    func fetchAllConversations() async throws -> [Conversation] {
        []
    }

    func markConversationRead(_: UUID) async throws {}
    func deleteConversation(_: UUID) async throws {}
    func unlinkConversations(for _: UUID, restoreImportSourceJID _: String) async throws {}
    func deleteConversations(for _: UUID) async throws {}
    func deleteContacts(for _: UUID) async throws {}
    func fetchLinkPreview(for _: String) async throws -> LinkPreview? {
        nil
    }

    func upsertLinkPreview(_: LinkPreview) async throws {}
}

private struct InMemoryCredentialStore: CredentialStore {
    func savePassword(_: String, for _: String) {}
    func loadPassword(for _: String) -> String? {
        nil
    }

    func deletePassword(for _: String) {}
}

// MARK: - Tests

enum AppDelegateTests {
    struct PerformShutdown {
        @Test
        @MainActor
        func `performShutdown returns within disconnectDeadline + slack on an empty environment`() async {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let environment = AppEnvironment(
                store: EmptyPersistenceStore(),
                transcripts: FileTranscriptStore(baseDirectory: tempDir),
                credentialStore: InMemoryCredentialStore()
            )

            // No accounts and no in-flight service tasks, so both the bounded
            // `disconnectAll(within:)` race and `shutdown(within:)` must return
            // promptly — a regression that swapped `withTaskGroup`'s
            // wait-for-all-children back in would exceed the deadline + slack.
            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await AppDelegate.performShutdown(environment)
            }
            #expect(elapsed < AppDelegate.disconnectDeadline + .seconds(1))
        }

        @Test
        @MainActor
        func `disconnectDeadline matches the documented bound`() {
            // Locks down the 3 s budget cited in `AppDelegate`'s comment so
            // a contributor who tightens or loosens it does so deliberately.
            #expect(AppDelegate.disconnectDeadline == .seconds(3))
        }
    }
}
