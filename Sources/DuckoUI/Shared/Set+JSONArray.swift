import Foundation

extension Set<String> {
    /// The set a string preference holds as a JSON array. Empty when the text is no such array.
    init(jsonArray: String) {
        self.init((try? JSONDecoder().decode([String].self, from: Data(jsonArray.utf8))) ?? [])
    }

    /// The set as a JSON array, sorted so that equal sets are stored alike.
    var jsonArray: String {
        (try? JSONEncoder().encode(sorted())).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}
