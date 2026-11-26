import Foundation
import Testing
@testable import DuckoCore

struct FileCredentialStoreTests {
    private func makeTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-credentials-\(UUID().uuidString).json")
    }

    @Test func `save and load`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret123", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "secret123")
    }

    @Test func `update overwrites`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("first", for: "alice@example.com")
        store.savePassword("second", for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == "second")
    }

    @Test func `load non existent returns nil`() {
        let url = makeTempURL()
        let store = FileCredentialStore(fileURL: url)
        #expect(store.loadPassword(for: "nobody@example.com") == nil)
    }

    @Test func `delete removes entry`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret", for: "alice@example.com")
        store.deletePassword(for: "alice@example.com")
        #expect(store.loadPassword(for: "alice@example.com") == nil)
    }

    @Test func `delete non existent does not throw`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.deletePassword(for: "nobody@example.com")
    }

    @Test func `persists across instances`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store1 = FileCredentialStore(fileURL: url)
        store1.savePassword("persist-me", for: "bob@example.com")

        let store2 = FileCredentialStore(fileURL: url)
        let loaded = store2.loadPassword(for: "bob@example.com")
        #expect(loaded == "persist-me")
    }

    @Test func `special characters round trip`() {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        let password = "p@$$w0rd!&*(){}[]|<>?"
        store.savePassword(password, for: "alice@example.com")
        let loaded = store.loadPassword(for: "alice@example.com")
        #expect(loaded == password)
    }

    @Test func `persisted file is owner-only`() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("secret123", for: "alice@example.com")
        let mode = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
    }

    // MARK: - Secrets and concurrent writers

    /// A fresh directory for a test's credentials file.
    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Restores write permission before removing, since some tests make the directory read-only.
    private func removeDirectory(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func `an existing passwords-only file still loads`() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"alice@example.com":"pw-alice","bob@example.com":"pw-bob"}"#.utf8).write(to: url)

        let store = FileCredentialStore(fileURL: url)
        #expect(store.loadPassword(for: "alice@example.com") == "pw-alice")
        #expect(store.loadPassword(for: "bob@example.com") == "pw-bob")
        #expect(try store.loadSecret(for: "alice@example.com") == nil)
    }

    @Test func `secrets round trip and never collide with a password of the same name`() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let secret = Data([0x00, 0xFF, 0x10, 0x7B, 0x22])

        let store = FileCredentialStore(fileURL: url)
        store.savePassword("pw", for: "sso-grant:alice@example.com")
        try store.saveSecret(secret, for: "sso-grant:alice@example.com")
        #expect(try store.loadSecret(for: "sso-grant:alice@example.com") == secret)
        #expect(store.loadPassword(for: "sso-grant:alice@example.com") == "pw")
        #expect(try FileCredentialStore(fileURL: url).loadSecret(for: "sso-grant:alice@example.com") == secret)

        try store.deleteSecret(for: "sso-grant:alice@example.com")
        #expect(try store.loadSecret(for: "sso-grant:alice@example.com") == nil)
        #expect(store.loadPassword(for: "sso-grant:alice@example.com") == "pw")
        try store.deleteSecret(for: "never-stored")
    }

    @Test func `two stores on one file writing in turn keep each other's writes`() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FileCredentialStore(fileURL: url)
        let second = FileCredentialStore(fileURL: url)

        first.savePassword("pw-alice", for: "alice@example.com")
        second.savePassword("pw-bob", for: "bob@example.com")
        try first.saveSecret(Data("grant-alice".utf8), for: "sso-grant:alice@example.com")
        #expect(try second.loadSecret(for: "sso-grant:alice@example.com") == Data("grant-alice".utf8))
        try second.saveSecret(Data("grant-bob".utf8), for: "sso-grant:bob@example.com")
        first.deletePassword(for: "carol@example.com")

        let reader = FileCredentialStore(fileURL: url)
        #expect(reader.loadPassword(for: "alice@example.com") == "pw-alice")
        #expect(reader.loadPassword(for: "bob@example.com") == "pw-bob")
        #expect(try reader.loadSecret(for: "sso-grant:alice@example.com") == Data("grant-alice".utf8))
        #expect(try reader.loadSecret(for: "sso-grant:bob@example.com") == Data("grant-bob".utf8))
    }

    @Test func `a failed write throws for a secret`() throws {
        let directory = try makeTempDirectory()
        defer { removeDirectory(directory) }
        let url = directory.appendingPathComponent("credentials.json")
        let store = FileCredentialStore(fileURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

        #expect(throws: (any Error).self) { try store.saveSecret(Data("grant".utf8), for: "sso-grant:alice@example.com") }
        store.savePassword("pw", for: "alice@example.com")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: ["not json", #"{"alice@example.com":42}"#, #"["alice@example.com"]"#])
    func `a malformed file stays byte for byte intact after a secret write and after a password write`(contents: String) throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data(contents.utf8)
        try original.write(to: url)
        let store = FileCredentialStore(fileURL: url)

        #expect(throws: (any Error).self) { try store.saveSecret(Data("grant".utf8), for: "sso-grant:alice@example.com") }
        #expect(try Data(contentsOf: url) == original)
        #expect(throws: (any Error).self) { try store.loadSecret(for: "sso-grant:alice@example.com") }
        #expect(throws: (any Error).self) { try store.deleteSecret(for: "sso-grant:alice@example.com") }
        store.savePassword("pw", for: "alice@example.com")
        store.deletePassword(for: "alice@example.com")
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func `an unreadable file stays byte for byte intact after a secret write and after a password write`() throws {
        let directory = try makeTempDirectory()
        defer { removeDirectory(directory) }
        let url = directory.appendingPathComponent("credentials.json")
        let original = Data(#"{"alice@example.com":"pw-alice"}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let store = FileCredentialStore(fileURL: url)

        #expect(throws: (any Error).self) { try store.saveSecret(Data("grant".utf8), for: "sso-grant:alice@example.com") }
        store.savePassword("pw-new", for: "bob@example.com")

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o000)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == original)
    }
}
