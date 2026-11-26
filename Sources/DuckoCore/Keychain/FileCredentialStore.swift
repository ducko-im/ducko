import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

/// Stores passwords and secrets as plaintext JSON on disk. Intended for development only.
///
/// Another process using the same profile may write the file too, so every write re-reads it and applies only its own
/// change, and secrets are read from the file each time.
public final class FileCredentialStore: CredentialStore, @unchecked Sendable {
    // Thread-safe via OSAllocatedUnfairLock — all mutable state accessed only inside withLock.
    private let lock = OSAllocatedUnfairLock(initialState: [String: String]())
    private let fileURL: URL
    private let log = Logger(label: "im.ducko.core.filecredentialstore")

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let existing = try? Self.load(from: fileURL) {
            lock.withLock { $0 = existing }
        }
    }

    public func savePassword(_ password: String, for jid: String) {
        do {
            try update { $0[jid] = password }
            log.debug("Saved password for \(jid) (file-based, not Keychain)")
        } catch {
            log.warning("Failed to write credentials file: \(error.localizedDescription)")
        }
    }

    public func loadPassword(for jid: String) -> String? {
        lock.withLock { $0[jid] }
    }

    public func deletePassword(for jid: String) {
        do {
            try update { _ = $0.removeValue(forKey: jid) }
        } catch {
            log.warning("Failed to write credentials file: \(error.localizedDescription)")
        }
    }

    public func saveSecret(_ data: Data, for key: String) throws {
        try update { $0[Self.secretKey(key)] = data.base64EncodedString() }
    }

    public func loadSecret(for key: String) throws -> Data? {
        try lock.withLock { entries in
            entries = try Self.load(from: fileURL)
            return try entries[Self.secretKey(key)].map(Self.decodeSecret)
        }
    }

    public func deleteSecret(for key: String) throws {
        try update { _ = $0.removeValue(forKey: Self.secretKey(key)) }
    }

    /// Applies `change` to the file as stored now. A file that cannot be read stays as it is.
    private func update(_ change: @Sendable (inout [String: String]) -> Void) throws {
        try lock.withLock { entries in
            var current = try Self.load(from: fileURL)
            change(&current)
            try JSONEncoder().encode(current).writeOwnerOnly(to: fileURL)
            entries = current
        }
    }

    /// Prefixed so a secret's key never collides with an account address.
    private static func secretKey(_ key: String) -> String {
        "secret:\(key)"
    }

    private static func decodeSecret(_ encoded: String) throws -> Data {
        guard let data = Data(base64Encoded: encoded) else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    /// A missing file holds nothing. Any other read or decode failure throws.
    private static func load(from url: URL) throws -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        }
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
