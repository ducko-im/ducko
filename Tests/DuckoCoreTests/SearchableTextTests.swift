import Foundation
import Testing
@testable import DuckoCore

struct SearchableTextTests {
    /// What a search may take on a text of some hundred kilobytes. The ones bounded here take milliseconds, and
    /// seconds once a text is searched as it stands or walked anew for every occurrence.
    private static let bound: Duration = .seconds(1)

    /// One character: `letter` under `marks` combining accents.
    private static func character(_ letter: String, marks: Int) -> String {
        letter + String(repeating: "\u{301}", count: marks)
    }

    private static func found(_ query: String, in text: String) -> [String] {
        SearchableText(text).ranges(of: query).map { String(text[$0]) }
    }

    @Test(arguments: [("Meet at the Café", "cafe"), ("100 m²", "2"), ("रामायण", "राम")])
    func `a text is searched by the rules of a search for user-entered text`(text: String, query: String) {
        #expect(text.localizedStandardContains(query))
        #expect(SearchableText(text).contains(query))
    }

    /// A keyword may begin or end inside a character: a letter without the vowel sign that follows it, an emoji
    /// without its skin tone, one emoji of a joined family, one half of a line break of two code points.
    @Test(arguments: [
        ("Café, CAFE and cafeteria", "cafe", ["Café", "CAFE", "cafe"]), ("aaa", "aa", ["aa"]), ("nothing here", "cafe", []),
        ("रामायण", "राम", ["रामा"]), ("👍🏽 ok", "👍", ["👍🏽"]), ("👨‍👩‍👧 and 👩", "👩", ["👨‍👩‍👧", "👩"]),
        ("one\r\ntwo", "\r", ["\r\n"]), ("one\r\ntwo", "\n", ["\r\n"])
    ])
    func `every occurrence is listed in order with the whole characters it covers`(text: String, query: String, occurrences: [String]) {
        #expect(Self.found(query, in: text) == occurrences)
    }

    /// What people write has to be searched whole, so a limit set too low shows here.
    @Test(arguments: [("मैं रामायण पढ़ता हूँ", "हूँ"), ("the 👨🏽‍👩🏽‍👧🏽‍👦🏽 went home", "👨🏽‍👩🏽‍👧🏽‍👦🏽"), ("Z̸̢̛͎a̴͖͝l̷̰͑g̶̣͐o̵͉͗ text", "zalgo")])
    func `a character of several code points is searched`(text: String, query: String) {
        #expect(SearchableText(text).contains(query))
    }

    @Test func `a character of more code points than the limit is left out, and the text around it is found where it stands`() {
        let limit = SearchableText.characterLimit
        let text = "stack " + Self.character("x", marks: limit) + " gnu and x"

        #expect(SearchableText(Self.character("x", marks: limit - 1)).contains("x"))
        #expect(!SearchableText(Self.character("x", marks: limit)).contains("x"))
        #expect(Self.found("gnu", in: text) == ["gnu"])
        #expect(SearchableText(text).ranges(of: "x") == [text.index(before: text.endIndex) ..< text.endIndex])
    }

    /// Half of such a character's code points may stand before its letter, as these number signs do, and half behind.
    @Test func `a character over the limit is left out whichever side of its letter its code points stand on`() throws {
        let half = SearchableText.characterLimit / 2
        let text = String(repeating: "\u{600}", count: half) + Self.character("a", marks: half) + " b"
        try #require(text.first?.unicodeScalars.count == SearchableText.characterLimit + 1)

        #expect(!SearchableText(text).contains("a"))
        #expect(SearchableText(text).contains("b"))
    }

    /// Searched as it stands, each of these takes seconds: one mark over and over, marks of two and of four combining
    /// classes in turn, and marks with a zero-width non-joiner between them under a keyword that begins with a mark. What
    /// that last keyword finds is the system search's to say.
    @Test(arguments: [
        ("\u{301}", "world", 1), ("\u{301}\u{323}", "world", 1), ("\u{345}\u{301}\u{323}\u{334}", "world", 1),
        ("\u{301}\u{200C}", "\u{301}z", nil)
    ])
    func `a character built from thousands of code points does not hold the search up`(marks: String, query: String, count: Int?) {
        let text = "hello a" + String(repeating: marks, count: 60000 / marks.unicodeScalars.count) + " world z"
        var occurrences = 0

        let elapsed = ContinuousClock().measure {
            occurrences = SearchableText(text).ranges(of: query).count
        }

        if let count {
            #expect(occurrences == count)
        }
        #expect(elapsed < Self.bound)
    }

    /// The text holds as many code points whatever the limit is, so a limit set far too high shows here.
    @Test func `characters at the limit do not hold the search up`() {
        let limit = SearchableText.characterLimit
        let character = "a" + String(repeating: "\u{301}\u{323}\u{334}", count: (limit - 1) / 3)
        let text = String(repeating: character, count: 120_000 / limit) + " world"
        var isFound = false

        let elapsed = ContinuousClock().measure {
            isFound = SearchableText(text).contains("world")
        }

        #expect(isFound)
        #expect(elapsed < Self.bound)
    }

    @Test(arguments: [("hay needle ", "needle", 12000), ("🇩🇪", "🇩🇪", 30000)])
    func `many occurrences are listed in the time of one walk through the text`(piece: String, query: String, count: Int) {
        let text = String(repeating: piece, count: count)
        var occurrences = 0

        let elapsed = ContinuousClock().measure {
            occurrences = SearchableText(text).ranges(of: query).count
        }

        #expect(occurrences == count)
        #expect(elapsed < Self.bound)
    }

    @Test func `a query of marks alone is not found`() throws {
        let text = "क़िला"
        let found = try #require(text.range(of: "\u{93C}", options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        try #require(found.isEmpty)

        #expect(!SearchableText(text).contains("\u{93C}"))
    }
}
