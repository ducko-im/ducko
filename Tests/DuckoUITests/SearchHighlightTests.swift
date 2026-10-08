import Foundation
import SwiftUI
import Testing
@testable import DuckoCore
@testable import DuckoUI

struct SearchHighlightTests {
    /// The stretches of `text` that carry the highlight, code point for code point: read as characters, a stretch that
    /// covers part of a character would show as the whole of it.
    private func highlighted(_ text: AttributedString) -> [String] {
        text.runs.filter { $0.backgroundColor == .yellow }.map { String(String.UnicodeScalarView(text[$0.range].unicodeScalars)) }
    }

    @Test func `every occurrence is highlighted, ignoring case and diacritics`() {
        let text = highlightingMatches(of: "cafe", in: AttributedString("Café, CAFE and cafeteria"))

        #expect(highlighted(text) == ["Café", "CAFE", "cafe"])
        #expect(String(text.characters) == "Café, CAFE and cafeteria")
    }

    @Test(arguments: [("100 m²", "2", "²"), ("① first", "1", "①")])
    func `what a search folds into the query is highlighted`(body: String, query: String, match: String) {
        #expect(body.localizedStandardContains(query))
        #expect(highlighted(highlightingMatches(of: query, in: AttributedString(body))) == [match])
    }

    /// A keyword may begin or end inside a character, and the search lists the whole character for it. The highlight has
    /// to land on that character's own code points, also for an occurrence behind one that is highlighted already.
    @Test(arguments: [("👨‍👩‍👧 and 👩", "👩", ["👨‍👩‍👧", "👩"]), ("one\r\ntwo", "\n", ["\r\n"])])
    func `a match that covers part of a character highlights the whole character`(body: String, query: String, matches: [String]) {
        let text = highlightingMatches(of: query, in: AttributedString(body))

        #expect(highlighted(text) == matches)
        #expect(String(text.characters) == body)
    }

    /// The search leaves out a letter under more marks than a character is searched with, which keeps such a text from
    /// holding a row up each time it draws.
    @Test func `a character of too many code points is not highlighted, and an occurrence behind it is`() {
        let body = "x" + String(repeating: "\u{301}", count: SearchableText.characterLimit) + " and x"

        #expect(highlighted(highlightingMatches(of: "x", in: AttributedString(body))) == ["x"])
    }

    @Test func `a text without the query comes back as it was`() {
        let text = AttributedString("nothing to see")

        #expect(highlightingMatches(of: "cafe", in: text) == text)
    }

    @Test func `the attributes a text came with are kept`() throws {
        let link = try #require(URL(string: "https://example.com/menu"))
        var text = AttributedString("see the cafe menu")
        text.link = link
        text.inlinePresentationIntent = .stronglyEmphasized

        let result = highlightingMatches(of: "cafe", in: text)

        #expect(highlighted(result) == ["cafe"])
        #expect(result.runs.allSatisfy { $0.link == link && $0.inlinePresentationIntent == .stronglyEmphasized })
    }
}
