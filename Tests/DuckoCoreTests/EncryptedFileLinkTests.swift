import Foundation
import Testing
@testable import DuckoCore

/// The IV and key of XEP-0454's own example, 88 hex digits.
private let secret = "8c3d050e9386ec173861778f68e9af38a97aaf82faa4063b4d0878a61261534410c8a84331eaac851759f587"
private let path = "download.montague.tld/4a771ac1-f0b2-4a4a-9700-f2a26fa2bb67/tr%C3%A8s%20cool.jpg"
private let link = "aesgcm://\(path)#\(secret)"
/// 113 Unicode scalars, 88 of them the IV and key.
private let shortLink = "aesgcm://h.example/f.jpg#\(secret)"

struct EncryptedFileLinkTests {
    // MARK: - Parsing

    @Test(arguments: [
        link, "aesgcm://\(path)#\(secret.uppercased())", "\(link)\ndata:image/jpeg,/9j/4AAQSkZJRgABAQEBLAEsAAD",
        "\(link)\ndata:image/jpeg;base64,/9j/4AAQSkZJRgABAQEBLAEsAAD"
    ])
    func `a body that is one aesgcm link, with or without a thumbnail, shares the file`(body: String) throws {
        let file = try #require(EncryptedFileLink(body: body))

        #expect(file.downloadURL.absoluteString == "https://\(path)")
        #expect(file.initializationVector == Array(hexBytes(secret).prefix(12)))
        #expect(file.key == Array(hexBytes(secret).dropFirst(12)))
        #expect(file.fileName == "très cool.jpg")
        let attachment = file.attachment()
        #expect(attachment.url == body.split(separator: "\n").first.map(String.init))
        #expect(attachment.mimeType == "image/jpeg")
        #expect(attachment.displayFileName == "très cool.jpg")
        // Nothing hands the link to a loader or a browser.
        #expect(attachment.remoteURL == nil)
    }

    @Test(arguments: [
        "aesgcm://\(path)#\(secret)0123456789ab",
        "aesgcm://\(path)#\(secret.dropLast(2))",
        "aesgcm://\(path)#\(secret.dropLast())g",
        "\(link) and some text",
        "Look: \(link)",
        "\(link)\n",
        "\(link)\ndata:image/png,iVBORw0KGgo",
        "\(link)\ndata:image/jpeg,/9j/4AAQ\nmore",
        "https://\(path)#\(secret)",
        "aesgcm:///files/cool.jpg#\(secret)",
        "aesgcm://user:pass@\(path)#\(secret)"
    ])
    func `any other body stays text`(body: String) {
        #expect(EncryptedFileLink(body: body) == nil)
    }

    // MARK: - Hiding keys

    @Test func `the key of every link a text mentions is hidden, and a hidden key stays as it is`() {
        let text = "first \(link) then AESGCM://h.example/b.pdf#\(secret)\tlast"
        let hidden = EncryptedFileLink.hidingKeys(in: text).body

        #expect(hidden == "first aesgcm://\(path)#… then AESGCM://h.example/b.pdf#…\tlast")
        #expect(EncryptedFileLink.hidingKeys(in: hidden).body == hidden)
    }

    /// The quote of a reply's fallback is counted in Unicode scalars of the body as received. Hiding a key inside it
    /// shrinks it by the scalars removed, and hiding one before it moves it, so it still covers exactly the quote.
    @Test(arguments: [
        ("> \(shortLink)\nmine", 0 ..< 116, "> aesgcm://h.example/f.jpg#…\nmine", 0 ..< 29),
        ("\(shortLink) > quoted\nmine", 114 ..< 123, "aesgcm://h.example/f.jpg#… > quoted\nmine", 27 ..< 36),
        ("> quoted\n\(shortLink)", 0 ..< 9, "> quoted\naesgcm://h.example/f.jpg#…", 0 ..< 9)
    ])
    func `a reply's quote keeps covering the same text once a key is hidden`(
        body: String, range: Range<Int>, expectedBody: String, expectedRange: Range<Int>
    ) {
        let hidden = EncryptedFileLink.hidingKeys(in: body, replyFallbackRange: range)

        #expect(hidden.body == expectedBody)
        #expect(hidden.replyFallbackRange == expectedRange)
    }
}

private func hexBytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
