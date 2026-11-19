import Testing

/// Polls `predicate` on the main actor until it holds, failing the test when it doesn't within `boundedOutcome`'s
/// deadline.
public func eventually(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ predicate: @escaping @MainActor () async throws -> Bool
) async throws {
    let poll = Task { @MainActor in
        while try await !predicate() {
            try Task.checkCancellation(); await Task.yield()
        }
    }
    // A predicate that never holds would otherwise keep yielding on the main actor after the test fails.
    defer { poll.cancel() }
    let result = try await boundedOutcome { try await poll.value }
    try #require(result != nil, "Condition did not hold in time", sourceLocation: sourceLocation)
    try result?.get()
}
