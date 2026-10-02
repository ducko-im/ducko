import AppKit

enum HTMLAttributedStringParser {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSAttributedString>()

    static func parse(_ html: String) -> AttributedString? {
        let key = html as NSString
        if let cached = cache.object(forKey: key) {
            return AttributedString(cached)
        }

        guard let data = html.data(using: .utf8) else { return nil }
        guard let nsAttr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        var attributed = AttributedString(nsAttr)
        // Strip font and color from every run, not just the top level.
        // NSAttributedString(html:) applies per-run fonts (e.g. Helvetica 12pt from
        // Adium logs). Preserve bold/italic traits as InlinePresentationIntent so
        // structural formatting survives while the view's inherited font takes over.
        for run in attributed.runs {
            let range = run.range
            if let nsFont = run.appKit.font {
                let traits = nsFont.fontDescriptor.symbolicTraits
                var intents = run.inlinePresentationIntent ?? []
                if traits.contains(.bold) {
                    intents.insert(.stronglyEmphasized)
                }
                if traits.contains(.italic) {
                    intents.insert(.emphasized)
                }
                if !intents.isEmpty {
                    attributed[range].inlinePresentationIntent = intents
                }
            }
            attributed[range].appKit.font = nil
            attributed[range].appKit.foregroundColor = nil
            attributed[range].appKit.backgroundColor = nil
        }

        cache.setObject(NSAttributedString(attributed), forKey: key)
        return attributed
    }
}
