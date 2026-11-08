import Testing
@testable import DuckoCLI

struct PlainRefusalTests {
    @Test
    func `A stored account's hint names account set`() {
        #expect(plainRefusalHint(.storedAccount, jid: "alice@example.com") == "Run 'ducko account set alice@example.com --allow-plain' to send the password to this server.")
    }

    @Test
    func `account add's hint re-runs it with --allow-plain and never names account set`() {
        let hint = plainRefusalHint(.accountAdd(host: nil, port: nil), jid: "alice@example.com")
        #expect(hint.contains("ducko account add alice@example.com --allow-plain"))
        #expect(!hint.contains("account set"))
    }

    @Test
    func `account add's hint keeps the host and port it was given`() {
        let hint = plainRefusalHint(.accountAdd(host: "xmpp.example.net", port: 5299), jid: "alice@example.com")
        #expect(hint.contains("ducko account add alice@example.com --host xmpp.example.net --port 5299 --allow-plain"))
    }
}
