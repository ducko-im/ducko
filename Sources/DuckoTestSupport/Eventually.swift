import Testing

/// Polls `predicate` on the main actor until it holds, failing the test when it doesn't within `boundedOutcome`'s
/// deadline.
public func eventually(_ predicate: @escaping @MainActor () async throws -> Bool) async throws {
    let result = try await boundedOutcome { @MainActor in
        while try await !predicate() {
            try Task.checkCancellation(); await Task.yield()
        }
    }
    try #require(result != nil)
    try result?.get()
}
