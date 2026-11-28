import DuckoCore
import DuckoTestSupport
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

/// `/savefile` decrypts into Downloads the file a contact last shared in an encrypted message, and only such a file.
@MainActor
struct SaveFileREPLTests {
    private static let plaintext = Array("A file only the chat's members can read.".utf8)

    /// A REPL session whose chat with bob holds the messages `messages` makes for the chat's id.
    private static func context(
        downloads: URL, fixture: EncryptedFileFixture, messages: (UUID) throws -> [ChatMessage]
    ) async throws -> REPLContext {
        let transcripts = MockTranscriptStore()
        let environment = AppEnvironment(
            store: MockPersistenceStore(), transcripts: transcripts, credentialStore: NullCredentialStore(),
            downloadsDirectory: downloads, encryptedFileDownload: fixture.download
        )
        let accountID = UUID()
        let conversation = try await environment.chatService.openConversation(jidString: "bob@example.com", accountID: accountID)
        try await transcripts.appendMessages(messages(conversation.id))
        return try REPLContext(formatter: JSONFormatter(), environment: environment, accountID: accountID, accountJID: #require(BareJID.parse("alice@example.com")))
    }

    /// A message from bob, or from this account when `outgoing`, sharing `link` as the chat stores it: an attachment
    /// named after the link's file.
    private static func message(
        in conversationID: UUID, sharing link: String, encrypted: Bool, at offset: TimeInterval, outgoing: Bool = false, retracted: Bool = false
    ) throws -> ChatMessage {
        let file = try #require(EncryptedFileLink(link: link)).attachment()
        return ChatMessage(
            id: UUID(), conversationID: conversationID, fromJID: outgoing ? "alice@example.com" : "bob@example.com", body: "",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset), isOutgoing: outgoing, isDelivered: false,
            isEdited: false, type: "chat", isRetracted: retracted, isEncrypted: encrypted, attachments: [file]
        )
    }

    /// A text message from bob in the chat, which shares no file.
    private static func text(in conversationID: UUID, at offset: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversationID, fromJID: "bob@example.com", body: "Hi",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset), isOutgoing: false, isDelivered: false,
            isEdited: false, type: "chat", isEncrypted: true
        )
    }

    private static func record(_ line: String) throws -> [String: String] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])
    }

    @Test func `the last encrypted file is decrypted and saved to Downloads`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        let older = try EncryptedFileFixture(plaintext: Array("An older file.".utf8), fileName: "older.png")
        try await withTemporaryDirectory { directory in
            let downloads = directory.appending(path: "Downloads")
            let context = try await Self.context(downloads: downloads, fixture: fixture) { conversationID in
                try [
                    Self.message(in: conversationID, sharing: older.link, encrypted: true, at: 0),
                    Self.message(in: conversationID, sharing: fixture.link, encrypted: true, at: 1)
                ]
            }

            let record = try await Self.record(saveFileREPLLine("bob@example.com", context: context))

            let path = try #require(record["path"])
            #expect(record["type"] == "command_result")
            #expect(record["action"] == "save_encrypted_file")
            #expect(URL(filePath: path).deletingLastPathComponent().standardizedFileURL == downloads.standardizedFileURL)
            #expect(URL(filePath: path).lastPathComponent == "photo.png")
            #expect(try Array(Data(contentsOf: URL(filePath: path))) == Self.plaintext)
            #expect(fixture.fetches.count == 1)
        }
    }

    /// A link that arrived in a plaintext message is no encrypted file, so it is not fetched.
    @Test func `a chat without an encrypted file is reported and nothing is fetched`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        try await withTemporaryDirectory { directory in
            let downloads = directory.appending(path: "Downloads")
            let context = try await Self.context(downloads: downloads, fixture: fixture) { conversationID in
                try [Self.message(in: conversationID, sharing: fixture.link, encrypted: false, at: 0)]
            }

            let record = try await Self.record(saveFileREPLLine("bob@example.com", context: context))

            #expect(record == ["type": "error", "message": "No encrypted file received from bob@example.com."])
            #expect(fixture.fetches.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: downloads.path))
        }
    }

    /// A file this account sent, such as one a carbon brings from its other device, and a file in a message the
    /// contact retracted are skipped for the one the contact shared before them.
    @Test(arguments: [(outgoing: true, retracted: false), (outgoing: false, retracted: true)])
    func `a newer file that was sent or retracted is skipped`(outgoing: Bool, retracted: Bool) async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        let newer = try EncryptedFileFixture(plaintext: Array("A newer file.".utf8), fileName: "newer.png")
        try await withTemporaryDirectory { directory in
            let downloads = directory.appending(path: "Downloads")
            let context = try await Self.context(downloads: downloads, fixture: fixture) { conversationID in
                try [
                    Self.message(in: conversationID, sharing: fixture.link, encrypted: true, at: 0),
                    Self.message(in: conversationID, sharing: newer.link, encrypted: true, at: 1, outgoing: outgoing, retracted: retracted)
                ]
            }

            let record = try await Self.record(saveFileREPLLine("bob@example.com", context: context))

            let path = try #require(record["path"])
            #expect(URL(filePath: path).lastPathComponent == "photo.png")
            #expect(fixture.fetches.count == 1)
        }
    }

    @Test func `a file shared before many newer messages is found`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        try await withTemporaryDirectory { directory in
            let downloads = directory.appending(path: "Downloads")
            let context = try await Self.context(downloads: downloads, fixture: fixture) { conversationID in
                try [Self.message(in: conversationID, sharing: fixture.link, encrypted: true, at: 0)]
                    + (1 ... 25).map { Self.text(in: conversationID, at: TimeInterval($0)) }
            }

            let record = try await Self.record(saveFileREPLLine("bob@example.com", context: context))

            let path = try #require(record["path"])
            #expect(try Array(Data(contentsOf: URL(filePath: path))) == Self.plaintext)
        }
    }
}
