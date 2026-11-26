import ArgumentParser
import DuckoCore
import Testing
@testable import DuckoCLI

struct AccountBrowserSignInTests {
    @Test func `parse browser-sign-in defaults`() throws {
        let command = try DuckoCLI.Account.BrowserSignIn.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
        #expect(!command.replacePassword)
        #expect(command.browserSignIn.clientID == nil)
        #expect(!command.browserSignIn.noBrowser)
    }

    @Test func `parse browser-sign-in with every option`() throws {
        let command = try DuckoCLI.Account.BrowserSignIn.parse(["alice@example.com", "--replace-password", "--client-id", "ducko", "--no-browser"])
        #expect(command.replacePassword)
        #expect(command.browserSignIn.clientID == "ducko")
        #expect(command.browserSignIn.noBrowser)
    }

    @Test func `account lists browser-sign-in among its subcommands`() {
        #expect(DuckoCLI.Account.configuration.subcommands.contains { $0.configuration.commandName == "browser-sign-in" })
    }

    @Test func `the redirect addresses an administrator's client allows are the app's and the loopback one, on one path`() throws {
        let uris = SSORedirect.redirectURIs(forIssuer: "https://auth.example.com")
        try #require(uris.count == 2)
        let appPrefix = "im.ducko:/oauth/callback/"
        let loopbackPrefix = "http://127.0.0.1/oauth/callback/"
        #expect(uris[0].hasPrefix(appPrefix), Comment(rawValue: uris[0]))
        #expect(uris[1].hasPrefix(loopbackPrefix), Comment(rawValue: uris[1]))
        let digest = uris[0].dropFirst(appPrefix.count)
        #expect(digest.count == 16 && digest.allSatisfy(\.isHexDigit), Comment(rawValue: uris[0]))
        #expect(uris[1].dropFirst(loopbackPrefix.count) == digest)
        #expect(SSORedirect.redirectURIs(forIssuer: "https://other.example.com") != uris)
    }
}
