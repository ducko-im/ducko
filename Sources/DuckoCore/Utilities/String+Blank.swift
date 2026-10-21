import Foundation

extension String {
    /// Whether the text is empty or only spaces, which a form field does not count as a value.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespaces).isEmpty
    }
}
