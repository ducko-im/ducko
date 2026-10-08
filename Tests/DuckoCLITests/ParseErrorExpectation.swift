import ArgumentParser
import Testing

/// Asserts that parsing `arguments` as `command` throws and the surfaced message names the specific cause, so a
/// regression in the wrong validation branch (or flag spelling) doesn't slip past a broad type match.
func expectParseError(
    _ command: (some ParsableCommand).Type, _ arguments: [String], containing substring: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let error = #expect(throws: (any Error).self, sourceLocation: sourceLocation) {
        _ = try command.parse(arguments)
    }
    #expect(String(describing: error).contains(substring), sourceLocation: sourceLocation)
}
