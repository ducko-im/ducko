import DuckoTestSupport
import Foundation
import os
import Testing
@testable import DuckoCore

/// Opening a file shared as an `aesgcm://` link: its bytes are decrypted in memory, its download is staged where only
/// the user can read it and removed afterwards, and nothing reaches the downloads folder.
@MainActor
struct EncryptedFileDecryptionTests {
    private static let plaintext = Array("A file only the chat's members can read.".utf8)

    private func link(_ fixture: EncryptedFileFixture) throws -> EncryptedFileLink {
        try #require(EncryptedFileLink(link: fixture.link))
    }

    @Test(arguments: [false, true])
    func `a download is staged privately and removed, and only a whole tag opens it`(tampersWithTag: Bool) async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext, tampersWithTag: tampersWithTag)
        try await withTemporaryDirectory { directory in
            let downloads = directory.appending(path: "Downloads")
            let service = FileTransferService(downloadsDirectory: downloads, encryptedFileDownload: fixture.download)

            let file = try link(fixture)
            let outcome: String
            do {
                outcome = try await service.decryptEncryptedFile(file) == Self.plaintext ? "opened" : "opened wrong"
            } catch {
                outcome = error.localizedDescription
            }

            let fetch = try #require(fixture.fetches.first)
            #expect(fixture.fetches.count == 1)
            #expect(fetch.mode == 0o600)
            #expect(fetch.sizeBeforeWrite == 0)
            #expect(!FileManager.default.fileExists(atPath: fetch.fileURL.path))
            #expect(!FileManager.default.fileExists(atPath: downloads.path))
            #expect(outcome == (tampersWithTag ? "Could not decrypt the file" : "opened"))
        }
    }

    /// The whole file is decrypted in memory, so its download is capped at the encrypted-file size, and a server that
    /// declares more than the cap is refused before its body is read.
    @Test func `an encrypted file's download is capped, and a file over the cap is refused`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        let server = try #require(LoopbackHTTPServer(responses: [.init(status: 200, body: fixture.encrypted)]))
        defer { server.stop() }
        let caps = OSAllocatedUnfairLock<[Int64]>(initialState: [])
        let service = FileTransferService(encryptedFileDownload: { _, fileURL, maxSize in
            caps.withLock { $0.append(maxSize) }
            return try await FileTransferService.fetchEncryptedFile(from: server.url(), into: fileURL, maxSize: Int64(fixture.encrypted.count) - 1)
        })

        await #expect {
            try await service.decryptEncryptedFile(link(fixture))
        } throws: { error in
            error.localizedDescription == "Could not download the file: The file is too large"
        }
        #expect(caps.withLock { $0 } == [FileTransferService.maxEncryptedFileSize])
    }

    /// The encrypted bytes are kept only in the staging file, so a response the server marks cacheable is fetched
    /// again rather than served from a URL cache.
    @Test func `an encrypted file is downloaded afresh each time, even when the server allows caching`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.plaintext)
        let cacheable = LoopbackHTTPServer.Response(status: 200, body: fixture.encrypted, extraHeaders: ["Cache-Control: max-age=3600"])
        let server = try #require(LoopbackHTTPServer(responses: [cacheable]))
        defer { server.stop() }
        let service = FileTransferService(encryptedFileDownload: { _, fileURL, maxSize in
            try await FileTransferService.fetchEncryptedFile(from: server.url(), into: fileURL, maxSize: maxSize)
        })

        for _ in 0 ..< 2 {
            #expect(try await service.decryptEncryptedFile(link(fixture)) == Self.plaintext)
        }
        #expect(server.requests.count == 2)
    }
}
