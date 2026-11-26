import DuckoCore
import Foundation
import os

struct MockCredentialStore: CredentialStore {
    struct Failure: Error {}

    private struct Failures {
        var saves = false
        var deletes = false
        var reads = false
        var passwordDeletes = false
    }

    private let storage = OSAllocatedUnfairLock(initialState: [String: String]())
    private let secrets = OSAllocatedUnfairLock(initialState: [String: Data]())
    private let failure = OSAllocatedUnfairLock(initialState: Failures())

    func savePassword(_ password: String, for jid: String) {
        storage.withLock { $0[jid] = password }
    }

    func loadPassword(for jid: String) -> String? {
        storage.withLock { $0[jid] }
    }

    func deletePassword(for jid: String) {
        if failure.withLock(\.passwordDeletes) { return }
        storage.withLock { $0[jid] = nil }
    }

    func saveSecret(_ data: Data, for key: String) throws {
        if failure.withLock(\.saves) { throw Failure() }
        secrets.withLock { $0[key] = data }
    }

    func loadSecret(for key: String) throws -> Data? {
        if failure.withLock(\.reads) { throw Failure() }
        return secrets.withLock { $0[key] }
    }

    func deleteSecret(for key: String) throws {
        if failure.withLock(\.deletes) { throw Failure() }
        secrets.withLock { $0[key] = nil }
    }

    /// Makes secret writes, deletes, or both throw from now on.
    func failSecretWrites(saves: Bool, deletes: Bool = false) {
        failure.withLock {
            $0.saves = saves
            $0.deletes = deletes
        }
    }

    /// Makes secret reads throw from now on, or stop throwing.
    func failSecretReads(_ fails: Bool) {
        failure.withLock { $0.reads = fails }
    }

    /// Keeps every password from now on, as a keychain whose delete fails would.
    func keepPasswordsOnDelete() {
        failure.withLock { $0.passwordDeletes = true }
    }
}
