import Foundation

public protocol CredentialStore: Sendable {
    func savePassword(_ password: String, for jid: String)
    func loadPassword(for jid: String) -> String?
    func deletePassword(for jid: String)
    func saveSecret(_ data: Data, for key: String) throws
    /// The data stored under `key`, nil when nothing is. A store that cannot be read throws.
    func loadSecret(for key: String) throws -> Data?
    /// Removes the data stored under `key`. Nothing stored counts as removed.
    func deleteSecret(for key: String) throws
}
