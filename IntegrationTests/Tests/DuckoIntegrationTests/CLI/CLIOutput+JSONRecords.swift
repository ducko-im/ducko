import Foundation
import Testing

extension CLIOutput {
    /// Each line of stdout as a JSON record, keeping only its string values. A line that is not a JSON object with a
    /// string `type`, a blank one included, fails the test.
    func jsonRecords(sourceLocation: SourceLocation = #_sourceLocation) throws -> [[String: String]] {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast(stdout.hasSuffix("\n") ? 1 : 0)
        return try lines.map { line in
            let object = try #require(
                try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], Comment(rawValue: "Not a JSON object: \(line)"),
                sourceLocation: sourceLocation
            )
            #expect(object["type"] is String, Comment(rawValue: String(line)), sourceLocation: sourceLocation)
            return object.compactMapValues { $0 as? String }
        }
    }
}
