import Testing
@testable import DuckoCore
@testable import DuckoUI

struct AdiumOnboardingImportViewTests {
    /// An empty keychain item counts as none, so its account shows its password field.
    @Test(arguments: [("secret", "secret"), (nil, nil), ("", nil)] as [(String?, String?)])
    func `only a non-empty keychain password is used`(stored: String?, used: String?) {
        #expect(AdiumOnboardingImportView.usableKeychainPassword(stored) == used)
    }

    /// An account without a keychain password starts ticked too, with its password field to fill.
    @Test func `every discovered account starts selected`() {
        let accounts = ["1", "2"].map {
            AdiumAccount(
                id: $0, service: "Jabber", uid: "user\($0)@example.com", connectServer: nil, connectPort: nil, resource: nil,
                requireTLS: true, autoConnect: true
            )
        }

        #expect(AdiumOnboardingImportView.initialSelection(for: accounts) == ["1", "2"])
    }
}
