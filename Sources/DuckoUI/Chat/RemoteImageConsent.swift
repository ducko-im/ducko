import Foundation
import Observation

/// The remote images the reader asked to load in one transcript, and the encrypted ones decrypted for it. Held outside
/// the rows, so an image stays loaded when its row scrolls out of view and its cell is reused. Deliberately not
/// persisted: the consent covers these images in this session, not every link the sender ever posts.
@MainActor @Observable
final class RemoteImageConsent {
    /// An encrypted image's decryption: under way, done, or failed. Its bytes are only ever held here, in memory.
    enum EncryptedImage {
        case loading
        case loaded(DecryptedImage)
        case failed
    }

    private var requestedAttachmentIDs: Set<UUID> = []
    private var encryptedImages: [UUID: EncryptedImage] = [:]

    func isRequested(_ attachmentID: UUID) -> Bool {
        requestedAttachmentIDs.contains(attachmentID)
    }

    func request(_ attachmentID: UUID) {
        requestedAttachmentIDs.insert(attachmentID)
    }

    func encryptedImage(_ attachmentID: UUID) -> EncryptedImage? {
        encryptedImages[attachmentID]
    }

    /// Decrypts an attachment's encrypted image with `decrypt`, unless it is loading or loaded already. A failed one is
    /// tried again.
    func loadEncryptedImage(_ attachmentID: UUID, decrypt: () async throws -> [UInt8]) async {
        switch encryptedImages[attachmentID] {
        case .loading, .loaded: return
        case .failed, nil: break
        }
        encryptedImages[attachmentID] = .loading
        let bytes = try? await decrypt()
        encryptedImages[attachmentID] = bytes.flatMap { DecryptedImage(bytes: $0) }.map { .loaded($0) } ?? .failed
    }
}
