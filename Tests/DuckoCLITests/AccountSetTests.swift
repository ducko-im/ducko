import Testing
@testable import DuckoCLI

struct AccountSetTests {
    @Test(arguments: [[], ["--allow-plain", "--no-allow-plain"], ["--require-tls", "--no-require-tls"]])
    func `account set needs one form of at least one setting`(flags: [String]) {
        #expect(throws: (any Error).self) { try DuckoCLI.Account.Set.parse(["alice@example.com"] + flags) }
    }

    @Test
    func `An omitted setting parses as unset`() throws {
        let allow = try DuckoCLI.Account.Set.parse(["alice@example.com", "--allow-plain"])
        #expect(allow.allowPlain == true && allow.requireTLS == nil)
        let optional = try DuckoCLI.Account.Set.parse(["alice@example.com", "--no-require-tls"])
        #expect(optional.requireTLS == false && optional.allowPlain == nil)
    }
}
