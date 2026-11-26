import Foundation
import Logging
import Security

private let log = Logger(label: "im.ducko.core.keychain")

/// Keychain store for account passwords and secrets. The service-string scope includes
/// `BuildEnvironment.appSupportDirectoryName` so dev (`Ducko-Dev` / `Ducko-Dev-<profile>`)
/// and release (`Ducko`) Keychain items never alias the same `(service, account)` tuple.
enum KeychainHelper {
    struct KeychainError: Error, CustomStringConvertible {
        let status: OSStatus

        var description: String {
            "OSStatus \(status)"
        }
    }

    private static let serviceName = "im.ducko.credentials.\(BuildEnvironment.appSupportDirectoryName)"

    private static func baseQuery(for jid: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: jid
        ]
    }

    /// Best effort: a failure is only logged.
    static func savePassword(_ password: String, for jid: String) {
        do {
            try saveSecret(Data(password.utf8), for: jid)
        } catch {
            log.error("Could not save a password: \(error)")
        }
    }

    static func loadPassword(for jid: String) -> String? {
        guard let data = try? loadSecret(for: jid) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Best effort: a password already gone counts as deleted, and any other failure is only logged.
    static func deletePassword(for jid: String) {
        do {
            try deleteSecret(for: jid)
        } catch {
            log.error("Could not delete a stored password: \(error)")
        }
    }

    // MARK: - Secrets

    /// Adds the item, or updates it when one is already stored under `key`. Like passwords, secrets go to the file-based
    /// login keychain, which ignores accessibility classes, so none is set.
    static func saveSecret(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError(status: updateStatus) }
        default:
            throw KeychainError(status: status)
        }
    }

    static func loadSecret(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError(status: errSecDecode) }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    static func deleteSecret(for key: String) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}
