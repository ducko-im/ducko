import DuckoCore
import SwiftUI

extension Text {
    /// `string`, with every occurrence of `query` highlighted when a query is given.
    init(_ string: String, highlighting query: String?) {
        if let query {
            self.init(highlightingMatches(of: query, in: AttributedString(string)))
        } else {
            self.init(string)
        }
    }
}

/// Returns `text` with every occurrence of `query` highlighted, as a message search finds it, and with every other
/// attribute as it was given.
func highlightingMatches(of query: String, in text: AttributedString) -> AttributedString {
    // Dark on yellow, since a bubble's own text color may be white.
    let highlight = AttributeContainer().backgroundColor(.yellow).foregroundColor(.black)
    var text = text
    for match in SearchableText(String(text.characters)).ranges(of: query) {
        // The range is taken from the text as it is now: one taken before an earlier highlight would no longer be
        // valid.
        if let range = Range(match, in: text) {
            text[range].mergeAttributes(highlight)
        }
    }
    return text
}
