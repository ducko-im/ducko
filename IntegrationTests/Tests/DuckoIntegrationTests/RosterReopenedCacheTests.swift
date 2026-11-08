import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoData

@MainActor
struct RosterReopenedCacheTests {
    enum Failure: Error { case beforeSave }

    @Test
    func `fresh authentication sends the reopened consistent roster version`() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UIRosterLoopbackServer()
        do {
            let port = try await server.start()
            let store = try SwiftDataPersistenceStore(modelContainer: ModelContainerFactory.makeContainer(at: directory))
            let account = try Account(id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, host: "127.0.0.1", port: Int(port), requireTLS: false, rosterVersion: "consistent", allowsPLAIN: true, createdAt: Date())
            try await store.saveAccount(account)
            await store.setBeforeRosterSaveForTesting { throw Failure.beforeSave }
            await #expect(throws: Failure.beforeSave) {
                _ = try await store.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([]), version: "failed"))
            }
            await store.setBeforeRosterSaveForTesting(nil)
            var stale = account
            stale.rosterVersion = "stale"
            stale.certificateFingerprint = "unrelated-save"
            try await store.saveAccount(stale)
            let reopened = try SwiftDataPersistenceStore(modelContainer: ModelContainerFactory.makeContainer(at: directory))
            #expect(try await reopened.fetchAccounts().first?.rosterVersion == "consistent")
            let credentials = FileCredentialStore(fileURL: directory.appending(path: "credentials.json"))
            let service = AccountService(store: reopened, credentialStore: credentials)
            do {
                try await service.loadAccounts()
                // Advance the persisted version after loading accounts so client creation must read it again.
                _ = try await reopened.applyRosterMutation(RosterMutation(accountID: account.id, contents: .snapshot([]), version: "new-consistent"))
                try await service.connect(accountID: account.id, password: "local-fixture")
                let versions = await server.requestedVersions
                #expect(versions.count == 1)
                #expect(versions.first == "new-consistent")
                await service.disconnect(accountID: account.id)
            } catch {
                await service.disconnect(accountID: account.id)
                throw error
            }
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}
