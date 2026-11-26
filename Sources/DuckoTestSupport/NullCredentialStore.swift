import DuckoCore
import Foundation

/// `CredentialStore` no-op for tests that do not exercise credentials.
public struct NullCredentialStore: CredentialStore {
    public init() {}
    public func savePassword(_ password: String, for jid: String) {}
    public func loadPassword(for jid: String) -> String? {
        nil
    }

    public func deletePassword(for jid: String) {}
    public func saveSecret(_ data: Data, for key: String) throws {}
    public func loadSecret(for key: String) throws -> Data? {
        nil
    }

    public func deleteSecret(for key: String) throws {}
}
