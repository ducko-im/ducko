private actor OutcomeBox {
    private(set) var result: Result<Void, any Error>?
    /// Signalled by whichever ends the wait first: the operation, the deadline, or the waiter's cancellation.
    let closed = AsyncSemaphore()

    func finish(_ result: Result<Void, any Error>) async {
        self.result = result
        await closed.signal()
    }
}

/// Runs `operation` in an unstructured task and waits up to `timeout` for it to finish, so an await that ignores
/// cancellation can't hang the test. Returns `nil` when the operation is still running at the deadline, and leaves it
/// running.
public func boundedOutcome(
    timeout: Duration = .seconds(2),
    of operation: @escaping @Sendable () async throws -> Void
) async throws -> Result<Void, any Error>? {
    let box = OutcomeBox()
    Task {
        do {
            try await operation()
            await box.finish(.success(()))
        } catch {
            await box.finish(.failure(error))
        }
    }
    let deadline = Task {
        try await Task.sleep(for: timeout)
        await box.closed.signal()
    }
    defer { deadline.cancel() }
    await withTaskCancellationHandler {
        await box.closed.wait()
    } onCancel: {
        Task { await box.closed.signal() }
    }
    if let result = await box.result { return result }
    try Task.checkCancellation()
    return nil
}

/// What `task` throws, waiting no longer than `boundedOutcome` does. Returns `nil` when it finishes without throwing or
/// is still running at the deadline, so a task that should fail fast cannot hang the test.
public func boundedFailure<Success: Sendable>(of task: Task<Success, any Error>) async throws -> (any Error)? {
    guard case let .failure(error) = try await boundedOutcome(of: { _ = try await task.value }) else { return nil }
    return error
}
