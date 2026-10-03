import ArgumentParser
import Testing
@testable import DuckoCLI

struct SendCommandParsingTests {
    @Test func `parse with file only`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == nil)
    }

    @Test func `parse with file and body`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "/tmp/photo.jpg", "alice@example.com", "Check this out"])
        #expect(command.file == "/tmp/photo.jpg")
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Check this out")
    }

    @Test func `parse with body only`() throws {
        let command = try DuckoCLI.Send.parse(["alice@example.com", "Hello"])
        #expect(command.file == nil)
        #expect(command.jid == "alice@example.com")
        #expect(command.body == "Hello")
    }

    @Test func `parse with no body no file fails validation`() {
        let error = #expect(throws: (any Error).self) {
            _ = try DuckoCLI.Send.parse(["alice@example.com"])
        }
        #expect(String(describing: error).contains("Provide a message body or --file <path>"))
    }

    // MARK: - --method flag

    @Test func `parse with method jingle`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "jingle", "alice@example.com"])
        #expect(command.method == "jingle")
        #expect(command.file == "test.txt")
    }

    @Test func `parse with method http`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "http", "alice@example.com"])
        #expect(command.method == "http")
    }

    @Test func `parse with method auto`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "--method", "auto", "alice@example.com"])
        #expect(command.method == "auto")
    }

    @Test func `parse without method defaults to nil`() throws {
        let command = try DuckoCLI.Send.parse(["--file", "test.txt", "alice@example.com"])
        #expect(command.method == nil)
    }
}

// MARK: - TransferMethodParsingTests

struct TransferMethodParsingTests {
    @Test func `parse auto method as an upload`() throws {
        let method = try parseTransferMethod("auto")
        #expect(method == .httpUpload)
    }

    @Test func `parse http method`() throws {
        let method = try parseTransferMethod("http")
        #expect(method == .httpUpload)
    }

    @Test func `parse jingle method`() throws {
        let method = try parseTransferMethod("jingle")
        #expect(method == .jingle)
    }

    @Test func `parse nil defaults to an upload`() throws {
        let method = try parseTransferMethod(nil)
        #expect(method == .httpUpload)
    }

    @Test func `parse case insensitive`() throws {
        let method = try parseTransferMethod("JINGLE")
        #expect(method == .jingle)
    }

    @Test func `parse invalid method throws`() {
        #expect(throws: CLIError.self) {
            _ = try parseTransferMethod("invalid")
        }
    }
}

// MARK: - SendFileArgsParsingTests

struct SendFileArgsParsingTests {
    @Test func `leading JID and path targets that recipient`() {
        let target = parseSendFileArgs("alice@example.com /tmp/photo.jpg", currentRoom: nil)
        #expect(target == .send(jidString: "alice@example.com", filePath: "/tmp/photo.jpg"))
    }

    @Test func `leading JID wins over current room`() {
        let target = parseSendFileArgs("alice@example.com /tmp/photo.jpg", currentRoom: "room@conference.example.com")
        #expect(target == .send(jidString: "alice@example.com", filePath: "/tmp/photo.jpg"))
    }

    @Test func `domain-only leading token is part of the path for current room`() {
        let target = parseSendFileArgs("example.com /tmp/photo.jpg", currentRoom: "room@conference.example.com")
        #expect(target == .send(jidString: "room@conference.example.com", filePath: "example.com /tmp/photo.jpg"))
    }

    @Test func `bare leading word is part of the path for current room`() {
        let target = parseSendFileArgs("Live /tmp/photo.jpg", currentRoom: "room@conference.example.com")
        #expect(target == .send(jidString: "room@conference.example.com", filePath: "Live /tmp/photo.jpg"))
    }

    @Test func `filename only sends to current room`() {
        let target = parseSendFileArgs("photo.jpg", currentRoom: "room@conference.example.com")
        #expect(target == .send(jidString: "room@conference.example.com", filePath: "photo.jpg"))
    }

    @Test func `lone JID reports missing path`() {
        let target = parseSendFileArgs("alice@example.com", currentRoom: "room@conference.example.com")
        #expect(target == .missingPath)
    }

    @Test func `path only with no current room has no target`() {
        let target = parseSendFileArgs("photo.jpg", currentRoom: nil)
        #expect(target == .noTarget)
    }
}
