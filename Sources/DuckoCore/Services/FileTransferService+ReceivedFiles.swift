import CoreServices
import CryptoKit
import DuckoXMPP
import Foundation

extension FileTransferService {
    /// Fetches a web address into an existing file, refusing a body over `maxSize`, and returns how many bytes it wrote.
    public typealias RemoteFileDownload = @Sendable (_ url: URL, _ fileURL: URL, _ maxSize: Int64) async throws -> Int64

    /// The largest encrypted file that is opened. It is decrypted in memory in one piece.
    nonisolated static let maxEncryptedFileSize: Int64 = 100 * 1024 * 1024

    /// The size of the authentication tag an encrypted file ends with (XEP-0454).
    private nonisolated static let encryptedFileTagLength = 16

    /// Downloads a file a peer linked to and saves it into `directory` the way `saveReceivedFile` does, with
    /// `fetchRemoteFile`'s checks.
    nonisolated static func downloadRemoteFile(
        from url: URL, named name: String, into directory: URL
    ) async throws -> (fileURL: URL, byteCount: Int64) {
        let stagingURL = try createStagingFile(named: "ducko-download", attributes: nil)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let byteCount = try await fetchRemoteFile(from: url, into: stagingURL, maxSize: maxDownloadSize, session: .shared)
        return try (saveReceivedFile(movingFrom: stagingURL, named: name, in: directory), byteCount)
    }

    /// Downloads and decrypts the file `link` shares, and returns its bytes. The file is AES-256-GCM encrypted with the
    /// link's IV and key, and its last 16 bytes are the tag. The encrypted bytes are staged in a file only the user can
    /// read, which is deleted whatever the outcome. The decrypted file reaches the disk only when the user saves it.
    public nonisolated func decryptEncryptedFile(_ link: EncryptedFileLink) async throws -> [UInt8] {
        let stagingURL = try Self.createStagingFile(named: "ducko-encrypted", attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let byteCount = try await encryptedFileDownload(link.downloadURL, stagingURL, min(Self.maxEncryptedFileSize, Self.maxDownloadSize))
        guard byteCount >= Self.encryptedFileTagLength else { throw FileTransferError.decryptionFailed }
        let encrypted: Data
        do {
            encrypted = try Data(contentsOf: stagingURL)
        } catch {
            throw FileTransferError.downloadFailed(error.localizedDescription)
        }
        guard encrypted.count == byteCount else {
            throw FileTransferError.downloadFailed("The download does not match the file size the server gave")
        }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: link.initializationVector),
                ciphertext: encrypted.dropLast(Self.encryptedFileTagLength),
                tag: encrypted.suffix(Self.encryptedFileTagLength)
            )
            return try Array(AES.GCM.open(box, using: SymmetricKey(data: link.key)))
        } catch {
            throw FileTransferError.decryptionFailed
        }
    }

    /// An empty file in the user's temporary directory, named after `prefix` and unique, with `attributes`.
    private nonisolated static func createStagingFile(named prefix: String, attributes: [FileAttributeKey: Any]?) throws -> URL {
        let stagingURL = FileManager.default.temporaryDirectory.appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil, attributes: attributes) else {
            throw FileTransferError.downloadFailed("The download could not be stored")
        }
        return stagingURL
    }

    /// Downloads an encrypted file as `fetchRemoteFile` does, through a session that keeps no cache, so its bytes are
    /// not also kept on disk.
    @Sendable
    public nonisolated static func fetchEncryptedFile(from url: URL, into fileURL: URL, maxSize: Int64) async throws -> Int64 {
        try await fetchRemoteFile(from: url, into: fileURL, maxSize: maxSize, session: uncachedSession)
    }

    private nonisolated static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// Downloads a file a peer linked to into `fileURL`, which exists. Only a web address is fetched, and only a 200 is
    /// kept. An error page or a partial response arrives as a status rather than an error, and saved under the file's
    /// name it would pass for the file. The server must declare the body's length and every byte of it must arrive,
    /// since a body cut off where its framing allows an end reads as a finished one. The body is streamed to disk and
    /// capped at `maxSize`.
    private nonisolated static func fetchRemoteFile(from url: URL, into fileURL: URL, maxSize: Int64, session: URLSession) async throws -> Int64 {
        guard url.isWebAddress else {
            throw FileTransferError.downloadFailed("The link is not a web address")
        }
        var request = URLRequest(url: url)
        // The declared length counts the bytes as sent, so a body decoded on arrival could not be checked against it.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                bytes.task.cancel()
                throw FileTransferError.downloadFailed("The file is not available at that link")
            }
            if let encoding = http.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                bytes.task.cancel()
                throw FileTransferError.downloadFailed("The server sent the file in a form whose size cannot be checked")
            }
            let expectedLength = response.expectedContentLength
            guard expectedLength >= 0 else {
                bytes.task.cancel()
                throw FileTransferError.downloadFailed("The server did not provide a file size")
            }
            guard expectedLength <= maxSize else {
                bytes.task.cancel()
                throw FileTransferError.downloadFailed("The file is too large")
            }
            return try await writeDownload(bytes, expectedLength: expectedLength, to: fileURL)
        } catch let error as FileTransferError {
            throw error
        } catch {
            throw FileTransferError.downloadFailed(error.localizedDescription)
        }
    }

    /// Streams a download to `fileURL`, which exists, in chunks, refusing a body that does not come to exactly
    /// `expectedLength` bytes.
    private nonisolated static func writeDownload(
        _ bytes: URLSession.AsyncBytes, expectedLength: Int64, to fileURL: URL
    ) async throws -> Int64 {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        let chunkSize = 64 * 1024
        var chunk: [UInt8] = []
        chunk.reserveCapacity(chunkSize)
        var total: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            guard chunk.count == chunkSize else { continue }
            total += Int64(chunk.count)
            guard total <= expectedLength else {
                bytes.task.cancel()
                throw FileTransferError.downloadFailed("The download does not match the file size the server gave")
            }
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
        }
        total += Int64(chunk.count)
        guard total == expectedLength else {
            throw FileTransferError.downloadFailed("The download does not match the file size the server gave")
        }
        try handle.write(contentsOf: chunk)
        return total
    }

    /// Writes a received file into `directory` under `name`, adding a number when that name is taken, and quarantines it
    /// like any other download. The name reaches here from a peer, so it is sanitized before it can become a path.
    nonisolated static func saveReceivedFile(_ bytes: [UInt8], named name: String, in directory: URL) async throws -> URL {
        let data = Data(bytes)
        return try placeReceivedFile(named: name, in: directory) { try data.write(to: $0, options: .withoutOverwriting) }
    }

    /// Moves a downloaded file into `directory` under `name`, with the same naming and quarantine as `saveReceivedFile`.
    nonisolated static func saveReceivedFile(movingFrom stagingURL: URL, named name: String, in directory: URL) throws -> URL {
        try placeReceivedFile(named: name, in: directory) { try FileManager.default.moveItem(at: stagingURL, to: $0) }
    }

    /// Places a received file under the first free variant of its sanitized name, using `write`, which must fail with
    /// `CocoaError.fileWriteFileExists` rather than replace a file already there, then quarantines it.
    private nonisolated static func placeReceivedFile(
        named name: String, in directory: URL, write: (URL) throws -> Void
    ) throws -> URL {
        let safeName = JingleFileDescription.sanitizeFileName(name)
        let nameURL = URL(filePath: safeName, directoryHint: .notDirectory)
        let stem = nameURL.deletingPathExtension().lastPathComponent
        let pathExtension = nameURL.pathExtension
        var written: URL?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for number in 1 ... 1000 {
                let candidate = number == 1 ? safeName : [stem + " \(number)", pathExtension].filter { !$0.isEmpty }.joined(separator: ".")
                let fileURL = directory.appending(path: candidate, directoryHint: .notDirectory)
                do {
                    try write(fileURL)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
                written = fileURL
                break
            }
        } catch {
            throw FileTransferError.fileSaveFailed(error.localizedDescription)
        }
        guard var fileURL = written else {
            throw FileTransferError.fileSaveFailed("Every name for the file is taken")
        }

        var values = URLResourceValues()
        // The file came from a contact in a chat, which is the provenance Gatekeeper should tell the user about.
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeInstantMessageAttachment as String]
        do {
            try fileURL.setResourceValues(values)
        } catch {
            // Unmarked, the file would open with none of the checks macOS gives a download, so it is not one this side
            // hands on as saved.
            try? FileManager.default.removeItem(at: fileURL)
            throw FileTransferError.fileSaveFailed(error.localizedDescription)
        }
        return fileURL
    }
}
