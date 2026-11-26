import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

struct CredentialHelperTests {
    @Test(arguments: [(4094, true), (4095, false)])
    func `A hidden line that fills the read buffer is refused`(length: Int, isTaken: Bool) {
        let line = String(repeating: "x", count: length)

        #expect((try? CredentialHelper.wholeHiddenLine(line)) == (isTaken ? line : nil))
    }

    /// A browser account signs in with its grant, so even a password left in the store is not asked for or used.
    @Test(arguments: [SignInMethod.password, .browser])
    func `A stored account's sign-in password is the stored one for a password account and none for a browser account`(method: SignInMethod) throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ducko-credentials-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileCredentialStore(fileURL: url)
        store.savePassword("stored", for: "alice@example.com")
        let account = try Account(
            id: UUID(), jid: #require(BareJID.parse("alice@example.com")), isEnabled: true, connectOnLaunch: false, signInMethod: method, createdAt: Date()
        )

        let password = try CredentialHelper.storedSignInPassword(for: account, using: store)

        switch method {
        case .password: #expect(password == "stored")
        case .browser: #expect(password == nil)
        }
    }
}
