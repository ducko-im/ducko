import DuckoCore
import DuckoXMPP
import Foundation
import Testing
@testable import DuckoCLI

// MARK: - PlainFormatter File Transfer Tests

struct PlainFileTransferFormatterTests {
    let formatter = PlainFormatter()

    // MARK: - formatTransferProgress

    @Test func `format transfer progress at zero`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("0%"))
        #expect(output.contains("1 MB"))
    }

    @Test func `format transfer progress at half`() {
        let output = formatter.formatTransferProgress(fileName: "doc.pdf", fileSize: 2_097_152, progress: 0.5)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("50%"))
    }

    @Test func `format transfer progress at complete`() {
        let output = formatter.formatTransferProgress(fileName: "video.mp4", fileSize: 10_485_760, progress: 1.0)
        #expect(output.contains("video.mp4"))
        #expect(output.contains("100%"))
    }

    // MARK: - formatFileMessage

    @Test func `format file message with size`() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
        #expect(output.contains("1 MB"))
    }

    @Test func `format file message without size`() {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://upload.example.com/doc.pdf", fileSize: nil)
        #expect(output.contains("doc.pdf"))
        #expect(output.contains("https://upload.example.com/doc.pdf"))
    }

    @Test func `format file offer`() {
        let output = formatter.formatFileOffer(fileName: "report.pdf", fileSize: 5_242_880, from: "bob@example.com", offerID: "offer-123")
        #expect(output.contains("report.pdf"))
        #expect(output.contains("MB"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("offer-123"))
        #expect(output.contains("/accept"))
        #expect(output.contains("/decline"))
    }

    @Test func `format jingle transfer progress`() {
        let output = formatter.formatJingleTransferProgress(fileName: "data.zip", fileSize: 10_485_760, progress: 0.75, state: "transferring")
        #expect(output.contains("data.zip"))
        #expect(output.contains("75%"))
        #expect(output.contains("transferring"))
    }

    @Test func `format jingle transfer completed`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456", transport: .socks5)
        #expect(output.contains("sid-456"))
        #expect(output.contains(" — SOCKS5"))
    }

    @Test func `format jingle transfer completed with ibb`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456", transport: .ibb)
        #expect(output.contains("sid-456"))
        #expect(output.contains(" — IBB"))
    }

    @Test func `format jingle transfer failed`() {
        let output = formatter.formatJingleTransferFailed(sid: "sid-789", reason: .disconnected)
        #expect(output == "error: The connection to the server was lost (sid: sid-789)")
    }

    @Test func `format transfer state marks a failure reason as an error`() {
        #expect(formatTransferState(transfer(in: .failed("You declined the transfer"))) == "error: You declined the transfer")
    }

    @Test func `format transfer state says where a received file was saved`() {
        #expect(formatTransferState(transfer(in: .received(fileURL: URL(filePath: "/tmp/ducko/notes.txt")))) == "saved to /tmp/ducko/notes.txt")
    }

    @Test func `format transfer state adds the rate and time left to a transferring row`() {
        var row = transfer(in: .transferring(progress: 0.5))
        #expect(formatTransferState(row) == "transferring 50%")
        row.rate = TransferRate(bytesPerSecond: 250_000, bytesTransferred: 5_000_000, totalBytes: 10_000_000)
        #expect(formatTransferState(row) == "transferring 50% · 250 kB/s · 20 sec left")
    }

    @Test func `a transfer lists its name, size, direction, method, state and session`() {
        var row = transfer(in: .transferring(progress: 0.5))
        row.sid = "s1"
        let line = "  notes.txt (10 MB) [outgoing/jingle] transferring 50% (sid: s1)"
        #expect(formatter.formatTransfer(row) == line)
        #expect(ANSIFormatter().formatTransfer(row) == line)
    }

    private func transfer(in state: FileTransferService.TransferState) -> FileTransferService.ActiveTransfer {
        FileTransferService.ActiveTransfer(
            id: UUID(), accountID: UUID(), fileName: "notes.txt", fileSize: 10_000_000, state: state, method: .jingle
        )
    }
}

// MARK: - ANSIFormatter File Transfer Tests

struct ANSIFileTransferFormatterTests {
    let formatter = ANSIFormatter()

    @Test func `format transfer progress contains carriage return`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.hasPrefix("\r"))
    }

    @Test func `format transfer progress contains ANSI codes`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("50%"))
    }

    @Test func `format transfer progress contains progress bar`() {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.5)
        #expect(output.contains("\u{2588}")) // filled block
        #expect(output.contains("\u{2591}")) // empty block
    }

    @Test func `format file message contains bold and cyan`() {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        #expect(output.contains("\u{001B}[1m")) // bold
        #expect(output.contains("\u{001B}[36m")) // cyan
        #expect(output.contains("photo.jpg"))
        #expect(output.contains("https://upload.example.com/photo.jpg"))
    }

    @Test func `format file offer contains yellow`() {
        let output = formatter.formatFileOffer(fileName: "report.pdf", fileSize: 5_242_880, from: "bob@example.com", offerID: "offer-123")
        #expect(output.contains("\u{001B}[33m")) // yellow
        #expect(output.contains("report.pdf"))
        #expect(output.contains("bob@example.com"))
        #expect(output.contains("offer-123"))
    }

    @Test func `format jingle transfer progress contains progress bar`() {
        let output = formatter.formatJingleTransferProgress(fileName: "data.zip", fileSize: 10_485_760, progress: 0.5, state: "transferring")
        #expect(output.hasPrefix("\r"))
        #expect(output.contains("\u{2588}")) // filled block
        #expect(output.contains("transferring"))
        #expect(output.contains("50%"))
    }

    @Test func `format jingle transfer completed contains green`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456", transport: .socks5)
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("sid-456"))
        #expect(output.contains(" \u{2014} SOCKS5"))
    }

    @Test func `format jingle transfer completed with ibb`() {
        let output = formatter.formatJingleTransferCompleted(sid: "sid-456", transport: .ibb)
        #expect(output.contains("\u{001B}[32m")) // green
        #expect(output.contains("sid-456"))
        #expect(output.contains(" \u{2014} IBB"))
    }

    @Test func `format jingle transfer failed contains red`() {
        let output = formatter.formatJingleTransferFailed(sid: "sid-789", reason: .timeout)
        #expect(output.contains("\u{001B}[31m")) // red
        #expect(output.contains("sid-789"))
        #expect(output.contains("The transfer timed out"))
    }
}

// MARK: - JSONFormatter File Transfer Tests

struct JSONFileTransferFormatterTests {
    let formatter = JSONFormatter()

    @Test func `format transfer progress is valid JSON`() throws {
        let output = formatter.formatTransferProgress(fileName: "photo.jpg", fileSize: 1_048_576, progress: 0.45)
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "transfer_progress")
        #expect(json["file_name"] == "photo.jpg")
        #expect(json["file_size"] == "1 MB")
        #expect(json["progress"] == "45")
    }

    @Test func formatTransferProgressAtComplete() throws {
        let output = formatter.formatTransferProgress(fileName: "doc.pdf", fileSize: 2_097_152, progress: 1.0)
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["progress"] == "100")
    }

    @Test func `format file message is valid JSON`() throws {
        let output = formatter.formatFileMessage(fileName: "photo.jpg", url: "https://upload.example.com/photo.jpg", fileSize: 1_048_576)
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["file_name"] == "photo.jpg")
        #expect(json["url"] == "https://upload.example.com/photo.jpg")
        #expect(json["file_size"] == "1 MB")
        #expect(json["file_size_bytes"] == "1048576")
    }

    @Test func `format file message without size omits file size`() throws {
        let output = formatter.formatFileMessage(fileName: "doc.pdf", url: "https://example.com/doc.pdf", fileSize: nil)
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file")
        #expect(json["file_size"] == nil)
        #expect(json["file_size_bytes"] == nil)
    }

    @Test func `a file offer event carries the offer id`() throws {
        let peer = try #require(FullJID.parse("bob@example.com/res"))
        let offer = JingleFileOffer(offerID: "offer-1", sid: "session-1", from: peer, fileName: "report.pdf", fileSize: 5_242_880)
        let output = try #require(formatter.formatEvent(.jingleFileTransferReceived(offer), accountID: UUID()))
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "file_offer")
        #expect(json["file_name"] == "report.pdf")
        #expect(json["from"] == "bob@example.com")
        #expect(json["offer_id"] == "offer-1")
        #expect(json["sid"] == "session-1")
        #expect(json["file_size"] == formatByteCount(5_242_880))
        #expect(json["file_size_bytes"] == "5242880")
    }

    struct TransferCase: Sendable, CustomTestStringConvertible {
        let state: FileTransferService.TransferState
        let fields: [String: String]

        var testDescription: String {
            fields["state"] ?? ""
        }
    }

    @Test(arguments: [
        TransferCase(state: .requestingSlot, fields: ["state": "requesting_slot"]),
        TransferCase(state: .uploading(progress: 0.25), fields: ["state": "uploading", "progress": "25"]),
        TransferCase(state: .uploading(progress: .nan), fields: ["state": "uploading"]),
        TransferCase(state: .completed(downloadURL: "https://example.com/a.bin"), fields: ["state": "completed", "url": "https://example.com/a.bin"]),
        TransferCase(state: .failed("The transfer timed out"), fields: ["state": "failed", "reason": "The transfer timed out"]),
        TransferCase(state: .negotiating, fields: ["state": "negotiating"]),
        TransferCase(state: .connectingTransport, fields: ["state": "connecting"]),
        TransferCase(state: .transferring(progress: 0.5), fields: ["state": "transferring", "progress": "50"]),
        TransferCase(state: .awaitingAcceptance, fields: ["state": "awaiting_acceptance"]),
        TransferCase(state: .completedTransfer, fields: ["state": "completed"]),
        TransferCase(state: .received(fileURL: URL(filePath: "/tmp/ducko/a.bin")), fields: ["state": "received", "path": "/tmp/ducko/a.bin"])
    ])
    func `a transfer record carries its state as a token, with the values that change in their own fields`(transferCase: TransferCase) throws {
        let accountID = UUID()
        let row = FileTransferService.ActiveTransfer(
            id: UUID(), accountID: accountID, fileName: "a.bin", fileSize: 10_000_000, state: transferCase.state,
            method: .jingle, direction: .incoming, sid: "s1", offerID: "o1"
        )
        let json = try transferRecord(row)
        #expect(json == transferCase.fields.merging([
            "type": "transfer", "file_name": "a.bin", "file_size": "10 MB", "file_size_bytes": "10000000",
            "direction": "incoming", "method": "jingle", "account": accountID.uuidString, "sid": "s1", "offer_id": "o1"
        ]) { $1 })
    }

    @Test func `an outgoing direct transfer has its offer id before its session`() throws {
        let row = FileTransferService.ActiveTransfer(
            id: UUID(), accountID: UUID(), fileName: "a.bin", fileSize: 10, state: .negotiating, method: .jingle, offerID: "o1"
        )
        let json = try transferRecord(row)
        #expect(json["offer_id"] == "o1")
        #expect(json["sid"] == nil)
        #expect(json["direction"] == "outgoing")
    }

    @Test func `an upload has neither a session nor an offer id`() throws {
        let row = FileTransferService.ActiveTransfer(id: UUID(), accountID: UUID(), fileName: "a.bin", fileSize: 10, state: .requestingSlot)
        let json = try transferRecord(row)
        #expect(json["method"] == "http")
        #expect(json["sid"] == nil)
        #expect(json["offer_id"] == nil)
    }

    @Test func `a transferring record adds the rate, and the time left only when it is known`() throws {
        var row = FileTransferService.ActiveTransfer(
            id: UUID(), accountID: UUID(), fileName: "a.bin", fileSize: 10_000_000, state: .transferring(progress: 0.5), method: .jingle
        )
        row.rate = TransferRate(bytesPerSecond: 250_000, bytesTransferred: 5_000_000, totalBytes: 10_000_000)
        let known = try transferRecord(row)
        #expect(known["bytes_per_second"] == "250000")
        #expect(known["seconds_remaining"] == "20")

        row.rate = TransferRate(bytesPerSecond: 250_000, bytesTransferred: 5_000_000, totalBytes: 0)
        let unknown = try transferRecord(row)
        #expect(unknown["bytes_per_second"] == "250000")
        #expect(unknown["seconds_remaining"] == nil)
    }

    private func transferRecord(_ row: FileTransferService.ActiveTransfer) throws -> [String: String] {
        let output = formatter.formatTransfer(row)
        expectSnakeCaseKeys(output)
        return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: String])
    }

    @Test func `a link offer event carries the offer id`() throws {
        let peer = try #require(FullJID.parse("bob@example.com/res"))
        let offer = OOBIQOffer(offerID: "offer-2", id: "stanza-2", from: .full(peer), url: "https://example.com/a.bin", desc: nil)
        let output = try #require(formatter.formatEvent(.oobIQOfferReceived(offer), accountID: UUID()))
        expectSnakeCaseKeys(output)
        let data = try #require(output.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(json["type"] == "oob_iq_offer")
        #expect(json["offer_id"] == "offer-2")
        #expect(json["id"] == "stanza-2")
    }
}
