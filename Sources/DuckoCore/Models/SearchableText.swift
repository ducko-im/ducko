import Foundation

/// A text as a message search reads it: ignoring case and diacritics, by the rules `localizedStandardContains` searches
/// with.
///
/// That search takes quadratic time over a character built from thousands of code points, such as a letter under a
/// long run of combining marks. A message holds as long a one as its sender likes. So a stand-in takes the place of a
/// character of more than `characterLimit` code points, and a letter under such a run is not found.
public struct SearchableText: Sendable {
    /// The most code points a character is searched with. Text people write stays well below it: a family of four
    /// emoji with skin tones holds eleven.
    static let characterLimit = 64

    private let original: String
    /// `original` with the stand-in for every character over the limit. It holds as many characters as `original`.
    private let searched: String

    public init(_ text: String) {
        self.original = text
        self.searched = Self.replacingLongCharacters(in: text)
    }

    public func contains(_ query: String) -> Bool {
        match(for: query, from: searched.startIndex) != nil
    }

    /// The characters of the text that each occurrence of `query` covers, in order. A match may begin or end inside a
    /// character, as a letter without the vowel sign that follows it or one emoji of a joined family does. It covers
    /// that character whole.
    public func ranges(of query: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        // The same character boundary in both texts. It is walked forward: asking for the characters around each match
        // would read a run of flags back to its start every time.
        var boundary = searched.startIndex
        var place = original.startIndex
        while let found = match(for: query, from: boundary) {
            var first = place
            while boundary < found.upperBound {
                if boundary <= found.lowerBound { first = place }
                searched.formIndex(after: &boundary)
                original.formIndex(after: &place)
            }
            ranges.append(first ..< place)
        }
        return ranges
    }

    private func match(for query: String, from start: String.Index) -> Range<String.Index>? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // A query of marks alone may be found as an empty range, which holds nothing to show.
        guard let found = searched.range(of: query, options: options, range: start ..< searched.endIndex, locale: .current), !found.isEmpty else {
            return nil
        }
        return found
    }

    /// The stand-in is a character of its own between any two others, so the characters before and after it stay
    /// what they were.
    private static func replacingLongCharacters(in text: String) -> String {
        guard mayHoldLongCharacter(text), text.contains(where: isLong) else { return text }
        return String(text.map { isLong($0) ? "\u{FFFC}" : $0 })
    }

    private static func isLong(_ character: Character) -> Bool {
        character.unicodeScalars.count > characterLimit
    }

    /// A character over the limit has at most one ASCII code point. At least half of its other code points therefore
    /// stand in a row on one side of that one, at two bytes or more each. A text without `characterLimit` such bytes in
    /// a row is spared the walk through its characters.
    private static func mayHoldLongCharacter(_ text: String) -> Bool {
        var run = 0
        for byte in text.utf8 {
            guard byte >= 0x80 else {
                run = 0
                continue
            }
            run += 1
            if run >= characterLimit { return true }
        }
        return false
    }
}
