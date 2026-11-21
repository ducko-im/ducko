import DuckoXMPP

/// Returns the first sent stanza that satisfies `predicate`, including one sent before the call.
/// Throws `XMPPClientError.timeout` if none is sent within `timeout`.
@discardableResult
public func awaitSent(
    on mock: MockTransport,
    timeout: Duration = .seconds(2),
    matching predicate: @escaping @Sendable (String) -> Bool
) async throws -> String {
    try await withThrowingTaskGroup(of: String?.self) { group in
        defer { group.cancelAll() }
        group.addTask { await mock.waitForSent(matching: predicate) }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw XMPPClientError.timeout
        }
        let result = try await group.next()!
        try Task.checkCancellation()
        guard let result else { throw XMPPClientError.timeout }
        return result
    }
}
