import DuckoCore
import Foundation
import Testing
@testable import DuckoCLI

private let secret = String(repeating: "0123456789abcdef", count: 5) + "01234567"

/// A file shared as an `aesgcm://` link (XEP-0454) is named in every output, while its link, which carries the file's
/// key, never is.
struct EncryptedFileFormatterTests {
    private static func attachment(_ name: String) -> DuckoCore.Attachment {
        DuckoCore.Attachment(id: UUID(), url: "aesgcm://upload.example.com/files/\(name)#\(secret)", mimeType: "application/pdf", fileName: name)
    }

    /// An encrypted message that shared two files, as history stores it: the first is named on the sender line, the
    /// second on a line of its own.
    private static let message = ChatMessage(
        id: UUID(), conversationID: UUID(), fromJID: "bob@example.com", body: "", timestamp: Date(), isOutgoing: false,
        isDelivered: false, isEdited: false, type: "chat", isEncrypted: true,
        attachments: [attachment("first.pdf"), attachment("second.pdf")]
    )

    @Test(arguments: OutputFormat.allCases)
    func `a history row names its encrypted files and never prints their links`(format: OutputFormat) throws {
        let output = format.makeFormatter().formatMessage(Self.message, accountJID: nil)

        #expect(output.contains("first.pdf"))
        #expect(output.contains("second.pdf"))
        #expect(!output.contains("aesgcm"))
        #expect(!output.contains(secret))
        if format == .json {
            let json = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
            #expect(json["attachments"] == "first.pdf,second.pdf")
            #expect(json["encrypted_file"] == "true")
        } else {
            #expect(output.contains("encrypted file"))
        }
    }

    @Test(arguments: OutputFormat.allCases)
    func `a file line for an encrypted file names it in place of its link`(format: OutputFormat) throws {
        let file = Self.attachment("report.pdf")
        let output = format.makeFormatter().formatFileMessage(fileName: file.displayFileName, url: file.url, fileSize: 2048)

        #expect(output.contains("report.pdf"))
        #expect(!output.contains("aesgcm"))
        #expect(!output.contains(secret))
        if format == .json {
            let json = try JSONDecoder().decode([String: String].self, from: Data(output.utf8))
            #expect(json["encrypted_file"] == "true")
            #expect(json["url"] == nil)
        } else {
            #expect(output.contains("encrypted file"))
        }
    }
}
