import DuckoXMPP
import Foundation

public struct Attachment: Sendable, Identifiable, Codable, Equatable {
    public var id: UUID
    public var url: String
    public var mimeType: String?
    public var fileName: String?
    public var fileSize: Int64?
    public var oobDescription: String?

    /// Where an attachment's bytes came from, which decides whether it may be opened from disk.
    public enum Origin: String, Sendable, Codable {
        /// Supplied by a peer, or otherwise not written by this app.
        case remote
        /// A file on this Mac that the user put there: one this app wrote to the downloads folder after a transfer the
        /// user accepted, or one the user chose to send directly.
        case locallySaved
    }

    /// Stored optionally so records written before provenance existed decode as `.remote`, which is the safe reading
    /// for anything this app cannot show it wrote itself.
    private var savedOrigin: Origin?

    /// Who supplied the attachment. A URL's scheme cannot answer this: a peer can send `file:` just as easily as this
    /// app writes it, so the scheme says where the bytes claim to live, never who chose the path.
    public var origin: Origin {
        savedOrigin ?? .remote
    }

    public init(
        id: UUID,
        url: String,
        mimeType: String? = nil,
        fileName: String? = nil,
        fileSize: Int64? = nil,
        oobDescription: String? = nil
    ) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileSize = fileSize
        self.oobDescription = oobDescription
        self.savedOrigin = .remote
    }

    /// An attachment for a file this app itself saved to the downloads folder, or one the user chose to send directly.
    /// The only way to reach `.locallySaved`, so provenance cannot be claimed by a caller parsing a peer's stanza.
    public static func locallySaved(
        id: UUID,
        fileURL: URL,
        mimeType: String? = nil,
        fileSize: Int64? = nil
    ) -> Attachment {
        var attachment = Attachment(
            id: id, url: fileURL.absoluteString, mimeType: mimeType,
            fileName: fileURL.lastPathComponent, fileSize: fileSize
        )
        attachment.savedOrigin = .locallySaved
        return attachment
    }

    /// The attachment's own file when it lives on disk, which is what makes Quick Look and Reveal in Finder possible.
    /// Only a file this app saved, or one the user chose to send directly, qualifies: a peer that sends a `file:` URL is
    /// naming a path on the recipient's machine, and honouring it would open the recipient's own documents inside the
    /// sender's message.
    public var localFileURL: URL? {
        guard origin == .locallySaved, let parsed = URL(string: url), parsed.isFileURL else { return nil }
        return parsed
    }

    /// The attachment's address on the web, restricted to the schemes an image loader or the browser may be handed.
    /// The string comes from a peer, so anything else — `file:`, a custom scheme, something unparseable — resolves to
    /// nothing rather than reaching a loader that would act on it.
    public var remoteURL: URL? {
        guard let parsed = URL(string: url), parsed.isWebAddress else { return nil }
        return parsed
    }

    public var isImage: Bool {
        mimeType?.hasPrefix("image/") == true
    }

    /// The name the attachment is shown under. Unless the file is one this app saved or the user chose to send, a peer
    /// chose the name, so it is reduced to one visible file name the way an offered file's is: a direction override or a
    /// control character could otherwise make it read as a different file.
    public var displayFileName: String {
        guard let fileName, !fileName.isEmpty else { return Self.fileName(forLink: url) }
        return origin == .locallySaved ? fileName : JingleFileDescription.sanitizeFileName(fileName)
    }

    /// The name a peer's link is shown and saved under: its last path component, reduced to one visible file name.
    public static func fileName(forLink link: String) -> String {
        JingleFileDescription.sanitizeFileName(URL(string: link)?.lastPathComponent ?? link)
    }

    public var formattedFileSize: String? {
        guard let fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

extension [Attachment] {
    /// Whether `body` only repeats one of these attachments' links, as the body of a shared file's message does.
    func areLinked(by body: String) -> Bool {
        contains { $0.url == body }
    }
}
