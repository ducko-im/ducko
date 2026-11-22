import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

struct ProfileFormatterTests {
    // MARK: - Plain

    @Test func `plain populated profile`() {
        let formatter = PlainFormatter()
        let profile = ProfileInfo(
            fullName: "Alice Smith",
            nickname: "alice",
            familyName: "Smith",
            givenName: "Alice",
            emails: [ProfileInfo.EmailEntry(address: "alice@example.com")],
            telephones: [ProfileInfo.TelephoneEntry(number: "+1234567890")],
            organization: "ACME",
            title: "Engineer",
            url: "https://example.com",
            birthday: "1990-01-01",
            note: "A note"
        )
        let output = formatter.formatProfile(profile)
        #expect(output.contains("Full Name: Alice Smith"))
        #expect(output.contains("Nickname: alice"))
        #expect(output.contains("Given Name: Alice"))
        #expect(output.contains("Family Name: Smith"))
        #expect(output.contains("Email: alice@example.com"))
        #expect(output.contains("Phone: +1234567890"))
        #expect(output.contains("Organization: ACME"))
        #expect(output.contains("Title: Engineer"))
        #expect(output.contains("URL: https://example.com"))
        #expect(output.contains("Birthday: 1990-01-01"))
        #expect(output.contains("Note: A note"))
    }

    @Test func `plain empty profile`() {
        let formatter = PlainFormatter()
        let profile = ProfileInfo()
        let output = formatter.formatProfile(profile)
        #expect(output == "(no profile data)")
    }

    // MARK: - ANSI

    @Test func `ansi populated profile has bold labels`() {
        let formatter = ANSIFormatter()
        let profile = ProfileInfo(fullName: "Bob", nickname: "bobby")
        let output = formatter.formatProfile(profile)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("Full Name:"))
        #expect(output.contains("Bob"))
        #expect(output.contains("Nickname:"))
        #expect(output.contains("bobby"))
    }

    @Test func `ansi empty profile uses dim`() {
        let formatter = ANSIFormatter()
        let profile = ProfileInfo()
        let output = formatter.formatProfile(profile)
        #expect(output.contains("\u{001B}[2m")) // dim
        #expect(output.contains("no profile data"))
    }

    @Test func `ansi url uses cyan`() {
        let formatter = ANSIFormatter()
        let profile = ProfileInfo(url: "https://example.com")
        let output = formatter.formatProfile(profile)
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("https://example.com"))
    }

    // MARK: - JSON

    @Test func `json populated profile`() {
        let formatter = JSONFormatter()
        let profile = ProfileInfo(
            fullName: "Carol",
            nickname: "carol",
            emails: [ProfileInfo.EmailEntry(address: "carol@example.com")],
            organization: "ACME"
        )
        let output = formatter.formatProfile(profile)
        expectSnakeCaseKeys(output)
        #expect(output.contains("\"type\":\"profile\""))
        #expect(output.contains("\"full_name\":\"Carol\""))
        #expect(output.contains("\"nickname\":\"carol\""))
        #expect(output.contains("\"emails\":[\"carol@example.com\"]"))
        #expect(output.contains("\"organization\":\"ACME\""))
    }

    @Test func `json profile with every field set carries each one`() throws {
        let profile = ProfileInfo(
            fullName: "Carol Jones", nickname: "carol", familyName: "Jones", givenName: "Carol",
            emails: [ProfileInfo.EmailEntry(address: "carol@example.com")], telephones: [ProfileInfo.TelephoneEntry(number: "+1234567890")],
            organization: "ACME", title: "Engineer", role: "Lead", url: "https://example.com", birthday: "1990-01-01", note: "A note"
        )
        let output = JSONFormatter().formatProfile(profile)
        expectSnakeCaseKeys(output)
        let json = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? NSDictionary)
        let expected: NSDictionary = [
            "type": "profile", "full_name": "Carol Jones", "nickname": "carol", "given_name": "Carol", "family_name": "Jones",
            "organization": "ACME", "title": "Engineer", "role": "Lead", "emails": ["carol@example.com"], "phones": ["+1234567890"],
            "url": "https://example.com", "birthday": "1990-01-01", "note": "A note"
        ]
        #expect(json == expected)
    }

    @Test func `json empty profile has only type`() {
        let formatter = JSONFormatter()
        let profile = ProfileInfo()
        let output = formatter.formatProfile(profile)
        #expect(output.contains("\"type\":\"profile\""))
        let noFullName = !output.contains("\"full_name\"")
        #expect(noFullName)
    }

    @Test func `json omits empty email entries`() {
        let formatter = JSONFormatter()
        let profile = ProfileInfo(emails: [ProfileInfo.EmailEntry(address: "")])
        let output = formatter.formatProfile(profile)
        let noEmails = !output.contains("\"emails\"")
        #expect(noEmails)
    }
}
