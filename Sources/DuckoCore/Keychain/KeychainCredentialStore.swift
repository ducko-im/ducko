import Foundation

struct KeychainCredentialStore: CredentialStore {
    func savePassword(_ password: String, for jid: String) {
        KeychainHelper.savePassword(password, for: jid)
    }

    func loadPassword(for jid: String) -> String? {
        KeychainHelper.loadPassword(for: jid)
    }

    func deletePassword(for jid: String) {
        KeychainHelper.deletePassword(for: jid)
    }

    func saveSecret(_ data: Data, for key: String) throws {
        try KeychainHelper.saveSecret(data, for: key)
    }

    func loadSecret(for key: String) throws -> Data? {
        try KeychainHelper.loadSecret(for: key)
    }

    func deleteSecret(for key: String) throws {
        try KeychainHelper.deleteSecret(for: key)
    }
}
