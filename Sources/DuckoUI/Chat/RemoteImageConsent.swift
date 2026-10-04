import Foundation
import Observation

/// The remote images the reader asked to load in one transcript. Held outside the rows, so an image stays loaded when
/// its row scrolls out of view and its cell is reused. Deliberately not persisted: the consent covers these images in
/// this session, not every link the sender ever posts.
@MainActor @Observable
final class RemoteImageConsent {
    private var requestedAttachmentIDs: Set<UUID> = []

    func isRequested(_ attachmentID: UUID) -> Bool {
        requestedAttachmentIDs.contains(attachmentID)
    }

    func request(_ attachmentID: UUID) {
        requestedAttachmentIDs.insert(attachmentID)
    }
}
