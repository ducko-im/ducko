import AppKit

enum HTMLAttributedStringParser {
    static func parse(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        guard let nsAttr = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return nil }
        var attributed = AttributedString(nsAttr)
        // An imported message can simply be set in a monospaced font, so the trait only means code where the
        // markup marks code.
        let marksCode = html.contains("<code")
        // Strip font and color from every run, not just the top level.
        // NSAttributedString(html:) applies per-run fonts (e.g. Helvetica 12pt from
        // Adium logs). Preserve bold/italic/monospaced traits as InlinePresentationIntent
        // so structural formatting survives while the view's inherited font takes over.
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
                if marksCode, traits.contains(.monoSpace) {
                    intents.insert(.code)
                }
                if !intents.isEmpty {
                    attributed[range].inlinePresentationIntent = intents
                }
            }
            attributed[range].appKit.font = nil
            attributed[range].appKit.foregroundColor = nil
            attributed[range].appKit.backgroundColor = nil
        }

        return attributed
    }
}
