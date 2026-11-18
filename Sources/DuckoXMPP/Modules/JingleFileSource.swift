import CryptoKit

/// Supplies the bytes of a file being sent, in order and a bounded chunk at a time, so a send never needs the whole file
/// in memory.
public protocol JingleFileSource: Sendable {
    /// Returns the next bytes of the file, at most `count` of them. An empty result means the file has ended.
    func read(upTo count: Int) async throws -> [UInt8]
}

extension JingleFileSource {
    /// Returns the next chunk of a send that still expects bytes. A file that ends early or cannot be read fails the send.
    func nextChunk(upTo count: Int) async throws -> [UInt8] {
        guard let chunk = try? await read(upTo: count), !chunk.isEmpty else {
            throw JingleModule.JingleError.transportFailed("The file could not be read")
        }
        return chunk
    }
}

/// Hashes a file fed to it in chunks, giving the digest in the form a `<hash algo='sha-256'>` element carries.
public struct JingleFileHasher {
    private var hasher = SHA256()

    public init() {}

    public mutating func update(_ bytes: [UInt8]) {
        hasher.update(data: bytes)
    }

    public func finalize() -> String {
        Base64.encode(Array(hasher.finalize()))
    }
}
