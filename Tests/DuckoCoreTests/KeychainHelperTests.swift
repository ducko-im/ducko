import Foundation
import Testing
@testable import DuckoCore

struct KeychainHelperTests {
    private func makeJID() -> String {
        "test-\(UUID().uuidString)@example.com"
    }

    private func makeSecretKey() -> String {
        "test-secret:\(UUID().uuidString)"
    }

    @Test func `save and load`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("secret123", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "secret123")
    }

    @Test func `update overwrites`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        KeychainHelper.savePassword("first", for: jid)
        KeychainHelper.savePassword("second", for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == "second")
    }

    @Test func `load non existent returns nil`() {
        let jid = makeJID()
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func `delete removes entry`() {
        let jid = makeJID()

        KeychainHelper.savePassword("toDelete", for: jid)
        KeychainHelper.deletePassword(for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == nil)
    }

    @Test func `delete non existent does not throw`() {
        let jid = makeJID()
        KeychainHelper.deletePassword(for: jid)
    }

    @Test func `special characters round trip`() {
        let jid = makeJID()
        defer { KeychainHelper.deletePassword(for: jid) }

        let password = "p@$$w0rd!&*(){}[]|<>?"
        KeychainHelper.savePassword(password, for: jid)
        let loaded = KeychainHelper.loadPassword(for: jid)
        #expect(loaded == password)
    }

    // MARK: - Secrets

    @Test func `saving a secret again overwrites it`() throws {
        let key = makeSecretKey()
        defer { try? KeychainHelper.deleteSecret(for: key) }

        try KeychainHelper.saveSecret(Data("first".utf8), for: key)
        try KeychainHelper.saveSecret(Data("second".utf8), for: key)
        #expect(try KeychainHelper.loadSecret(for: key) == Data("second".utf8))
    }

    @Test func `loading a missing secret returns nil`() throws {
        #expect(try KeychainHelper.loadSecret(for: makeSecretKey()) == nil)
    }

    @Test func `deleting a secret removes it, and deleting a missing one does not throw`() throws {
        let key = makeSecretKey()
        defer { try? KeychainHelper.deleteSecret(for: key) }

        try KeychainHelper.saveSecret(Data("secret".utf8), for: key)
        try KeychainHelper.deleteSecret(for: key)
        #expect(try KeychainHelper.loadSecret(for: key) == nil)
        try KeychainHelper.deleteSecret(for: key)
    }

    @Test func `a secret and a password in the same service keep to their own keys`() throws {
        let jid = makeJID()
        let key = makeSecretKey()
        defer {
            KeychainHelper.deletePassword(for: jid)
            try? KeychainHelper.deleteSecret(for: key)
        }

        KeychainHelper.savePassword("secret123", for: jid)
        try KeychainHelper.saveSecret(Data("grant".utf8), for: key)
        try KeychainHelper.saveSecret(Data("grant-2".utf8), for: key)
        #expect(KeychainHelper.loadPassword(for: jid) == "secret123")
        #expect(try KeychainHelper.loadSecret(for: key) == Data("grant-2".utf8))

        try KeychainHelper.deleteSecret(for: key)
        #expect(KeychainHelper.loadPassword(for: jid) == "secret123")
    }
}
