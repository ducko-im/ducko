import Foundation
import Testing

/// Records an issue for each key of the JSON record `json`, nested ones included, that is not snake_case, and for input
/// that is not a JSON object with a string `type`.
func expectSnakeCaseKeys(_ json: String, sourceLocation: SourceLocation = #_sourceLocation) {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
        Issue.record("Not a JSON object: \(json)", sourceLocation: sourceLocation)
        return
    }
    if !(object["type"] is String) {
        Issue.record("A record without a string type: \(json)", sourceLocation: sourceLocation)
    }
    for key in nonSnakeCaseKeys(in: object) {
        Issue.record("Key \(key) is not snake_case in \(json)", sourceLocation: sourceLocation)
    }
}

/// Each line of `output` as a JSON record, keeping only its string values. A line that is not a JSON object with a
/// string `type`, a blank one included, fails the test.
func jsonRecords(_ output: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [[String: String]] {
    try output.split(separator: "\n", omittingEmptySubsequences: false).dropLast(output.hasSuffix("\n") ? 1 : 0).map { line in
        let object = try #require(
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], Comment(rawValue: "Not a JSON object: \(line)"),
            sourceLocation: sourceLocation
        )
        #expect(object["type"] is String, Comment(rawValue: String(line)), sourceLocation: sourceLocation)
        return object.compactMapValues { $0 as? String }
    }
}

private func nonSnakeCaseKeys(in value: Any) -> [String] {
    switch value {
    case let object as [String: Any]:
        object.keys.filter { $0.wholeMatch(of: /[a-z][a-z0-9]*(_[a-z0-9]+)*/) == nil } + object.values.flatMap(nonSnakeCaseKeys)
    case let array as [Any]:
        array.flatMap(nonSnakeCaseKeys)
    default:
        []
    }
}
