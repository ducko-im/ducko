# Bug patterns

Real concurrency failure modes that LLMs produce frequently, with the preferred fix for each.

## Actor reentrancy: check-then-act across `await`

**Failure:** Actor method checks state, awaits, then acts on the stale check. Other callers may have mutated state during the suspension.

```swift
// BUG: Two callers can both see nil and both download.
// The force unwrap can crash if a third caller clears the cache mid-flight.
actor Cache {
    var data: [String: Data] = [:]

    func load(_ key: String) async throws -> Data {
        if data[key] == nil {
            data[key] = try await download(key)
        }
        return data[key]!
    }
}
```

**Fix:** Capture the async result into a local before writing. For deduplication, store in-flight `Task` handles so concurrent callers await the same computation:

```swift
actor Cache {
    private var data: [String: Data] = [:]
    private var inFlight: [String: Task<Data, any Error>] = [:]

    func load(_ key: String) async throws -> Data {
        if let cached = data[key] { return cached }
        if let task = inFlight[key] { return try await task.value }

        let task = Task {
            try await download(key)
        }
        inFlight[key] = task

        let result = try await task.value
        data[key] = result
        inFlight.removeValue(forKey: key)
        return result
    }
}
```

Multiple callers safely `await task.value` on the same `Task` handle — tasks are `Sendable` and thread-safe. See `actors.md` for more on reentrancy.


## Continuation resumed zero times

**Failure:** A `withCheckedThrowingContinuation` callback never fires (object deallocated, network timeout with no callback, early return before registering the handler, etc). The caller hangs forever.

**Fix:** Audit every code path to confirm the continuation is resumed. If the underlying API can silently drop the callback, add a timeout or restructure so the caller isn't left waiting. Always use `withCheckedThrowingContinuation` (not the unsafe variant) so that missed resumes are easier to diagnose.


## Continuation resumed twice

**Failure:** Two callbacks (e.g., a success handler and a cancellation handler) both resume the same continuation. `CheckedContinuation` traps at runtime; `UnsafeContinuation` causes undefined behavior.

**Fix:** Restructure the callback wiring so only one path can reach the continuation. If that isn't possible, guard with a `Bool` flag or use an `actor` to serialize access. Always default to `CheckedContinuation` so double resumes surface immediately during development and testing.


## Unstructured tasks in a loop

**Failure:** `for item in items { Task { await process(item) } }` creates fire-and-forget tasks with no cancellation propagation, no error collection, and no way to await completion.

**Fix:** Use `withTaskGroup` or `withThrowingTaskGroup`. See `structured.md`.


## Swallowed errors in Task closures

**Failure:** `Task { try await riskyWork() }` – if `riskyWork` throws, the error is silently lost. The user sees nothing; the operation just doesn't happen.

**Fix:** Handle the error inside the closure – show an alert, log to a visible surface, or propagate via a `@State` error property.

```swift
Task {
    do {
        try await riskyWork()
    } catch {
        self.errorMessage = error.localizedDescription
    }
}
```


## Blocking the main actor with synchronous work

**Failure:** CPU-intensive work runs on `@MainActor` (or inside `Task {}` called from `@MainActor`), causing UI freezes. In Swift 6.2 this is more likely because `nonisolated` async functions now stay on the caller's executor by default.

**Fix:** Move the expensive work into an explicitly offloaded function using `@concurrent`, or use `Task.detached` as a last resort.


## Unbounded AsyncStream buffer

**Failure:** A high-throughput producer yields values faster than the consumer processes them. With the default `.unbounded` buffering policy, memory grows without limit.

**Fix:** Specify `.bufferingNewest(n)` or `.bufferingOldest(n)`. See `async-streams.md`.


## Ignoring `CancellationError` in catch blocks

**Failure:** A `catch` block retries or shows an error alert for `CancellationError`, which is a normal lifecycle event (e.g., user navigated away).

**Fix:** Check for cancellation before handling other errors:

```swift
do {
    try await loadData()
} catch is CancellationError {
    // Normal – view disappeared or task was cancelled. Do nothing.
} catch {
    self.errorMessage = error.localizedDescription
}
```


## `@unchecked Sendable` hiding real races

**Failure:** A class is marked `@unchecked Sendable` to suppress compiler errors, but its mutable `var` properties have no synchronization. The data race still exists at runtime.

**Fix:** Restructure to use value types, use an `actor`, or move state behind a lock. See `bridging.md`.


## Self-await deadlock: cancel + await `value` from inside the very task

**Failure:** A handler running inside a stored unstructured `Task` cancels that task and then awaits its `value` to "wait for cleanup". The handler is the task — it cannot make progress while waiting for itself, and the await never returns.

```swift
// BUG: the read loop calls handle(_:), which calls tearDown(), which awaits
// `connectionTask.value` — but the read loop *is* connectionTask.
private var connectionTask: Task<Void, Never>?

func openConnection() {
    connectionTask = Task {
        for await message in inbound.messages(...) {
            await handle(message)
        }
    }
}

func tearDown() async {
    connectionTask?.cancel()
    await connectionTask?.value   // deadlock: awaiting the running task from inside itself
    connectionTask = nil
}
```

**Fix:** Cancel from inside, but let the task unwind naturally — clear state in the *parent* `Task`'s `defer`, or detach the cleanup so it isn't running on the awaited task.

```swift
connectionTask = Task {
    defer {
        Task { @MainActor in
            self.connectionTask = nil
            self.connectionState = .disconnected
        }
    }
    for await message in inbound.messages(...) {
        await handle(message)
    }
}

func tearDown() async {
    connectionTask?.cancel()   // unblocks the iterator with CancellationError
    // do NOT await connectionTask?.value here — the parent's defer clears state.
}
```

If the caller is **outside** the awaited task (e.g. a SwiftUI menu action, not a closure dispatched from the read loop), `await task.value` is safe. The pitfall only applies when the await would block the task that needs to complete to fulfill the await.


## Main-actor closure called on a framework's own queue

**Failure:** A non-`@Sendable` closure written inside a `@MainActor` type or function is inferred `@MainActor`. It may be passed to an Objective-C API whose callback parameter is not `@Sendable` (check the generated interface, not whether the framework is annotated elsewhere), and that API may call it on a queue of its own. In Swift 6 language mode the runtime isolation check then traps, for example with `EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`. It compiles without a warning. `ASWebAuthenticationSession`'s completion handler is one such callback: Apple documents no queue for it, and it was observed off the main queue when the user cancelled the sign-in.

**Fix:** Declare the closure's type explicitly `@Sendable`, so it stays nonisolated, and hop to the actor inside it:

```swift
let completion: @Sendable (URL?, (any Error)?) -> Void = { url, error in
    Task { @MainActor in
        handleSignInResult(url: url, error: error)
    }
}
let session = ASWebAuthenticationSession(url: url, callback: callback, completionHandler: completion)
```

When the closure only resumes a continuation, resume it directly; no hop is needed. See `bridging.md`.
