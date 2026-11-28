import CryptoKit
import DuckoCore
import Foundation
import os

/// A file shared as an `aesgcm://` link (XEP-0454), encrypted with a fixed IV and key so its bytes are the same on
/// every run, and a stand-in for its download that counts the fetches and records the staging file each one wrote to.
public final class EncryptedFileFixture: Sendable {
    /// One fetch: the staging file it was handed, and that file's POSIX mode and size before anything was written.
    public struct Fetch: Sendable {
        public let fileURL: URL
        public let mode: Int?
        public let sizeBeforeWrite: Int?
    }

    public static let initializationVector: [UInt8] = Array(0 ..< 12)
    public static let key: [UInt8] = Array(32 ..< 64)

    public let link: String
    public let plaintext: [UInt8]
    /// What the server serves: the ciphertext followed by the 16-byte tag.
    public let encrypted: [UInt8]
    private let recorded = OSAllocatedUnfairLock<[Fetch]>(initialState: [])

    /// `plaintext` shared as `fileName` on an upload host. With `tampersWithTag`, the served tag is wrong.
    public init(plaintext: [UInt8], fileName: String = "photo.png", tampersWithTag: Bool = false) throws {
        let secret = Self.initializationVector + Self.key
        self.link = "aesgcm://upload.example.com/files/\(fileName)#" + secret.map { String(format: "%02x", $0) }.joined()
        self.plaintext = plaintext
        // A fixed nonce keeps the fixture's bytes stable. Production never encrypts; this only stands in for a sender.
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: Self.key), nonce: AES.GCM.Nonce(data: Self.initializationVector))
        var encrypted = Array(sealed.ciphertext) + Array(sealed.tag)
        if tampersWithTag {
            encrypted[encrypted.count - 1] ^= 0x01
        }
        self.encrypted = encrypted
    }

    /// The fetches made so far, oldest first.
    public var fetches: [Fetch] {
        recorded.withLock { $0 }
    }

    /// Writes `encrypted` into the staging file it is handed, as a server's download would.
    public var download: FileTransferService.RemoteFileDownload {
        { [self] _, fileURL, _ in
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fetch = Fetch(
                fileURL: fileURL, mode: attributes?[.posixPermissions] as? Int, sizeBeforeWrite: (attributes?[.size] as? NSNumber)?.intValue
            )
            recorded.withLock { $0.append(fetch) }
            try Data(encrypted).write(to: fileURL)
            return Int64(encrypted.count)
        }
    }
}
