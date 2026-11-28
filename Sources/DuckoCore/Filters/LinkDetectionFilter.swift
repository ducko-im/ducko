import Foundation

/// Detects URLs in message bodies using NSDataDetector and populates `detectedURLs`.
struct LinkDetectionFilter: MessageFilter {
    let priority = 10

    init() {}

    func filter(_ content: MessageContent, direction: FilterDirection, context: FilterContext) async -> MessageContent {
        guard !content.body.isEmpty else { return content }

        let body = content.body
        let urls: [URL]
        do {
            let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let range = NSRange(body.startIndex..., in: body)
            let matches = detector.matches(in: body, range: range)
            // An `aesgcm://` link carries its file's key, so it is never linked or previewed (XEP-0454).
            urls = matches.compactMap(\.url).filter { !EncryptedFileLink.isMentioned(in: $0.absoluteString) }
        } catch {
            return content
        }

        guard !urls.isEmpty else { return content }

        return MessageContent(body: content.body, htmlBody: content.htmlBody, detectedURLs: urls)
    }
}
