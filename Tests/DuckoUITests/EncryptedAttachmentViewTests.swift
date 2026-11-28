import AppKit
import DuckoCore
import DuckoTestSupport
import SwiftUI
import Synchronization
import Testing
@testable import DuckoUI

/// A file shared as an `aesgcm://` link (XEP-0454) is fetched and decrypted under the rule a remote image is fetched
/// by, only in an encrypted message, and shown and saved from memory.
@MainActor
struct EncryptedAttachmentViewTests {
    /// How long a fetch that is not meant to happen is given to happen anyway.
    private static let settleTime = Duration.milliseconds(300)

    private static func pngBytes() throws -> [UInt8] {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try Array(#require(bitmap.representation(using: .png, properties: [:])))
    }

    private static func environment(_ fixture: EncryptedFileFixture, downloads: URL = FileManager.default.temporaryDirectory) -> AppEnvironment {
        AppEnvironment(
            store: MockPersistenceStore(), transcripts: MockTranscriptStore(), credentialStore: NullCredentialStore(),
            downloadsDirectory: downloads, encryptedFileDownload: fixture.download
        )
    }

    /// Shows `view` in a window, so it appears and runs its tasks as a chat row does.
    private static func show(_ view: some View) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return window
    }

    /// Whether the attachment's decryption, once it ends, has loaded the image. It waits on changes rather than a
    /// deadline, because the decryption ends in a main-actor turn that on a busy machine queues past any `eventually`
    /// deadline. The test's time limit bounds a decryption that never ends, and its cancellation counts as not loaded.
    private static func decryptionLoads(_ attachmentID: UUID, in consent: RemoteImageConsent) async -> Bool {
        while true {
            switch consent.encryptedImage(attachmentID) {
            case .loaded: return true
            case .failed: return false
            case .loading, nil:
                let wait = ChangeWait()
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        wait.hold(continuation)
                        withObservationTracking { _ = consent.encryptedImage(attachmentID) } onChange: { wait.resume() }
                    }
                } onCancel: {
                    wait.resume()
                }
                if Task.isCancelled { return false }
            }
        }
    }

    /// A received image in a message that came encrypted or in the clear, in a chat that loads images on sight or not.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (isEncrypted: true, loadsOnSight: true, fetchesOnSight: true, fetchesWhenAsked: true),
        (isEncrypted: true, loadsOnSight: false, fetchesOnSight: false, fetchesWhenAsked: true),
        (isEncrypted: false, loadsOnSight: true, fetchesOnSight: false, fetchesWhenAsked: false)
    ])
    func `an encrypted image is fetched as a remote image would be, and only from an encrypted message`(
        isEncrypted: Bool, loadsOnSight: Bool, fetchesOnSight: Bool, fetchesWhenAsked: Bool
    ) async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.pngBytes())
        let attachment = try #require(EncryptedFileLink(link: fixture.link)).attachment()
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "bob@example.com", body: "", timestamp: Date(), isOutgoing: false,
            isDelivered: true, isEdited: false, type: "chat", isEncrypted: isEncrypted, attachments: [attachment]
        )
        let consent = RemoteImageConsent()
        let content = MessageContentView(
            message: message, isGroupchatIncoming: false, isMetadataVisible: false, actionSenderName: "",
            loadsIncomingImagesOnSight: loadsOnSight, transferStatus: nil
        )
        let window = Self.show(content.environment(Self.environment(fixture)).environment(consent))
        defer { window.close() }

        if fetchesOnSight {
            #expect(await Self.decryptionLoads(attachment.id, in: consent))
        } else {
            try await Task.sleep(for: Self.settleTime)
            #expect(fixture.fetches.isEmpty)
        }

        // What tapping the image's placeholder asks for, and the redraw it brings.
        consent.request(attachment.id)
        window.layoutIfNeeded()
        if fetchesWhenAsked {
            #expect(await Self.decryptionLoads(attachment.id, in: consent))
        } else {
            try await Task.sleep(for: Self.settleTime)
            #expect(consent.encryptedImage(attachment.id) == nil)
        }
        #expect(fixture.fetches.count == (fetchesWhenAsked ? 1 : 0))
    }

    @Test func `an encrypted image's preview saves its decrypted bytes to the downloads folder`() async throws {
        let fixture = try EncryptedFileFixture(plaintext: Self.pngBytes())
        try await withTemporaryDirectory { downloads in
            let environment = Self.environment(fixture, downloads: downloads)

            try await ImagePreviewSheet.save(decryptedBytes: fixture.plaintext, orFetching: nil, named: "photo.png", with: environment.fileTransferService)

            #expect(try Data(contentsOf: downloads.appending(path: "photo.png")) == Data(fixture.plaintext))
            #expect(fixture.fetches.isEmpty)
        }
    }

    @Test func `a failed decryption is tried again by the next request, and a loaded one is not`() async throws {
        let consent = RemoteImageConsent()
        let attachmentID = UUID()
        let png = try Self.pngBytes()
        var attempts = 0

        await consent.loadEncryptedImage(attachmentID) {
            attempts += 1
            throw FileTransferService.FileTransferError.decryptionFailed
        }
        guard case .failed? = consent.encryptedImage(attachmentID) else {
            Issue.record("Expected a failed decryption, got \(String(describing: consent.encryptedImage(attachmentID)))")
            return
        }
        await consent.loadEncryptedImage(attachmentID) {
            attempts += 1
            return png
        }
        await consent.loadEncryptedImage(attachmentID) {
            attempts += 1
            return png
        }

        guard case let .loaded(decrypted)? = consent.encryptedImage(attachmentID) else {
            Issue.record("Expected a loaded image, got \(String(describing: consent.encryptedImage(attachmentID)))")
            return
        }
        #expect(decrypted.bytes == png)
        #expect(attempts == 2)
    }

    @Test func `decrypted bytes that are not an image fail`() async {
        let consent = RemoteImageConsent()
        let attachmentID = UUID()

        await consent.loadEncryptedImage(attachmentID) { Array("Not an image.".utf8) }

        guard case .failed? = consent.encryptedImage(attachmentID) else {
            Issue.record("Expected a failed decryption, got \(String(describing: consent.encryptedImage(attachmentID)))")
            return
        }
    }
}

/// A wait that ends once, at the first of an observed change and the waiting task's cancellation.
private final class ChangeWait: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    /// Holds `continuation` until `resume()`, or resumes it at once when the task is cancelled already.
    func hold(_ continuation: CheckedContinuation<Void, Never>) {
        let isCancelled = self.continuation.withLock { held in
            guard !Task.isCancelled else { return true }
            held = continuation
            return false
        }
        if isCancelled { continuation.resume() }
    }

    func resume() {
        let held = continuation.withLock { held in
            defer { held = nil }
            return held
        }
        held?.resume()
    }
}
