import ArgumentParser
import Testing
@testable import DuckoCLI

struct AccountAddTests {
    @Test func `parse add command`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.jid == "alice@example.com")
    }

    @Test func `parse add command with domain`() throws {
        let command = try DuckoCLI.Account.Add.parse(["test@xmpp.example.org"])
        #expect(command.jid == "test@xmpp.example.org")
    }

    @Test func `parse add command with password option`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com", "--password", "secret"])
        #expect(command.jid == "alice@example.com")
        #expect(command.password == "secret")
    }

    @Test func `parse add command defaults password to nil`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.password == nil)
    }

    @Test func `parse add command defaults host port and noConnect`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(command.endpoint.host == nil)
        #expect(command.endpoint.port == nil)
        #expect(command.noConnect == false)
    }

    @Test func `parse add command with host and port`() throws {
        let command = try DuckoCLI.Account.Add.parse([
            "alice@example.com", "--host", "127.0.0.1", "--port", "5223"
        ])
        #expect(command.endpoint.host == "127.0.0.1")
        #expect(command.endpoint.port == 5223)
    }

    @Test func `parse add command with no-connect flag`() throws {
        let command = try DuckoCLI.Account.Add.parse([
            "alice@example.com", "--host", "127.0.0.1", "--no-connect"
        ])
        #expect(command.noConnect == true)
    }

    @Test func `validate rejects --port without --host`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Add.parse(["alice@example.com", "--port", "5222"])
        }
        #expect(String(describing: error).contains("--port requires --host"))
    }

    @Test func `validate rejects --port 0`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Add.parse(["alice@example.com", "--host", "127.0.0.1", "--port", "0"])
        }
        #expect(String(describing: error).contains("--port must be between 1 and 65535"))
    }

    @Test(arguments: [UInt16(1), 65535])
    func `--port takes the ends of its range`(port: UInt16) throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com", "--host", "127.0.0.1", "--port", "\(port)"])
        #expect(command.endpoint.port == port)
    }

    @Test(arguments: [["--password", "secret"], ["--allow-plain"], ["--no-connect"]])
    func `--sso refuses the password options and --no-connect`(option: [String]) {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Add.parse(["alice@example.com", "--sso"] + option)
        }
        #expect(String(describing: error).contains("--sso cannot be combined with --password, --allow-plain or --no-connect."))
    }

    @Test(arguments: [["--client-id", "ducko"], ["--no-browser"]])
    func `the browser options need --sso`(option: [String]) {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Account.Add.parse(["alice@example.com"] + option)
        }
        #expect(String(describing: error).contains("--client-id and --no-browser need --sso."))
    }

    @Test func `--sso takes the endpoint and browser options`() throws {
        let command = try DuckoCLI.Account.Add.parse([
            "alice@example.com", "--sso", "--host", "127.0.0.1", "--port", "5223", "--client-id", "ducko", "--no-browser"
        ])
        #expect(command.sso)
        #expect(command.endpoint.host == "127.0.0.1")
        #expect(command.endpoint.port == 5223)
        #expect(command.browserSignIn.clientID == "ducko")
        #expect(command.browserSignIn.noBrowser)
    }

    @Test func `parse add command defaults to password sign-in`() throws {
        let command = try DuckoCLI.Account.Add.parse(["alice@example.com"])
        #expect(!command.sso)
        #expect(command.browserSignIn.clientID == nil)
        #expect(!command.browserSignIn.noBrowser)
    }
}
