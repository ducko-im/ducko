import DuckoXMPP
import Foundation
import UniformTypeIdentifiers

/// A file shared in an encrypted chat as an `aesgcm://` link (XEP-0454): the address of the encrypted file, with the
/// IV and key that open it in the fragment. Whoever holds the link can read the file, so the link itself is never
/// shown, copied, linkified or handed to a browser.
public struct EncryptedFileLink: Sendable, Equatable {
    /// The link as the sender wrote it, which the file's attachment keeps so it can be opened later.
    private let link: String
    /// Where the encrypted file is downloaded from: the link's address over HTTPS, without its fragment.
    public let downloadURL: URL
    /// The 12-byte IV of the file's AES-256-GCM encryption.
    let initializationVector: [UInt8]
    /// The 32-byte AES-256-GCM key.
    let key: [UInt8]

    private static let scheme = "aesgcm"
    private static let ivLength = 12
    private static let keyLength = 32

    /// The link a message's whole decrypted `body` shares: exactly one `aesgcm://` link, optionally followed by one
    /// newline and a JPEG thumbnail as a data URI. Nil for any other body, which stays text.
    public init?(body: String) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        switch lines.count {
        case 1:
            self.init(link: body)
        case 2 where Self.isJPEGDataURI(lines[1]):
            self.init(link: String(lines[0]))
        default:
            return nil
        }
    }

    /// `link` read as an `aesgcm://` link: a web host, and a fragment of exactly 88 hex digits holding the IV and then
    /// the key. Nil for anything else.
    public init?(link: String) {
        guard !link.unicodeScalars.contains(where: Self.isSeparator),
              var components = URLComponents(string: link),
              components.scheme?.lowercased() == Self.scheme,
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let fragment = components.percentEncodedFragment,
              fragment.utf8.count == 2 * (Self.ivLength + Self.keyLength),
              let secret = decodeHex(fragment.utf8)
        else { return nil }
        components.scheme = "https"
        components.fragment = nil
        guard let downloadURL = components.url else { return nil }
        self.link = link
        self.downloadURL = downloadURL
        self.initializationVector = Array(secret[..<Self.ivLength])
        self.key = Array(secret[Self.ivLength...])
    }

    /// The name the file is shown and saved under: the link's last path component.
    public var fileName: String {
        Attachment.fileName(forLink: downloadURL.absoluteString)
    }

    /// The file as an attachment of the message that shared it, typed by its name's extension.
    public func attachment() -> Attachment {
        Attachment(
            id: UUID(), url: link, mimeType: UTType(filenameExtension: downloadURL.pathExtension)?.preferredMIMEType, fileName: fileName
        )
    }

    /// Whether `text` mentions an `aesgcm://` link anywhere.
    public static func isMentioned(in text: String) -> Bool {
        text.range(of: "\(scheme)://", options: .caseInsensitive) != nil
    }

    /// `body` with the fragment of every `aesgcm://` link it mentions, the part that holds the key, replaced by `…`,
    /// and `replyFallbackRange`, counted in Unicode scalars of `body`, moved to cover the same text in the new body. A
    /// fragment ends at the first whitespace, so nothing of a key survives whatever follows it.
    public static func hidingKeys(in body: String, replyFallbackRange: Range<Int>? = nil) -> (body: String, replyFallbackRange: Range<Int>?) {
        let scalars = Array(body.unicodeScalars)
        let marker = Array("\(scheme)://".unicodeScalars)
        var hidden: [Range<Int>] = []
        var index = 0
        while index + marker.count <= scalars.count {
            guard zip(scalars[index...], marker).allSatisfy({ $0.properties.lowercaseMapping == String($1) }) else {
                index += 1
                continue
            }
            let end = scalars[index...].firstIndex(where: isSeparator) ?? scalars.count
            if let hash = scalars[index ..< end].firstIndex(of: "#"), hash + 1 < end, !scalars[(hash + 1) ..< end].elementsEqual([ellipsis]) {
                hidden.append((hash + 1) ..< end)
            }
            index = end
        }
        guard !hidden.isEmpty else { return (body, replyFallbackRange) }

        var view = String.UnicodeScalarView()
        var copied = 0
        for range in hidden {
            view.append(contentsOf: scalars[copied ..< range.lowerBound])
            view.append(ellipsis)
            copied = range.upperBound
        }
        view.append(contentsOf: scalars[copied...])
        let movedRange = replyFallbackRange.map { range in
            let lower = position(of: range.lowerBound, afterHiding: hidden, roundingUp: false)
            return lower ..< max(lower, position(of: range.upperBound, afterHiding: hidden, roundingUp: true))
        }
        return (String(view), movedRange)
    }

    private static let ellipsis: Unicode.Scalar = "\u{2026}"

    /// Where `offset` lands once each of `hidden`, ascending, is replaced by one scalar. An offset inside a hidden
    /// fragment lands before its replacement, or after it when `roundingUp`, so a range keeps the whole replacement.
    private static func position(of offset: Int, afterHiding hidden: [Range<Int>], roundingUp: Bool) -> Int {
        var removed = 0
        for range in hidden {
            if offset >= range.upperBound {
                removed += range.count - 1
            } else if offset > range.lowerBound {
                return range.lowerBound - removed + (roundingUp ? 1 : 0)
            } else {
                break
            }
        }
        return offset - removed
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || CharacterSet.controlCharacters.contains(scalar)
    }

    private static func isJPEGDataURI(_ line: Substring) -> Bool {
        let prefix = "data:image/jpeg"
        guard line.lowercased().hasPrefix(prefix), line.contains(",") else { return false }
        let next = line.dropFirst(prefix.count).first
        return (next == "," || next == ";") && !line.unicodeScalars.contains(where: isSeparator)
    }
}

extension EncryptedFileLink: CustomStringConvertible, CustomDebugStringConvertible {
    /// The link's address without its key, so interpolating a link into a log line or a test failure cannot leak it.
    public var description: String {
        downloadURL.absoluteString
    }

    public var debugDescription: String {
        "EncryptedFileLink(\(downloadURL.absoluteString))"
    }
}
