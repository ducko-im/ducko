# Testing concurrent code

Best practices for testing Swift Concurrency with Swift Testing (recommended) and XCTest.


## Async tests with Swift Testing

Swift Testing supports async test functions natively. No special setup:

```swift
@Test func userLoads() async throws {
    let user = try await UserService().load(id: "123")
    #expect(user.name == "Alice")
}
```

Do not wrap async work in `Task {}` or use expectations/semaphores inside Swift Testing tests — just make the test function `async`.


## Testing actor state

Access actor properties through `await` in tests, just like production code. Do not bypass actor isolation with `nonisolated` accessors added just for testing.

```swift
@Test func cachingWorks() async throws {
    let cache = ImageCache()
    let image = try await cache.image(for: testURL)
    let cached = try await cache.image(for: testURL)
    #expect(image == cached)
}
```


## The `.serialized` trait and concurrent tests

Swift Testing runs tests in parallel by default, which is usually what you want for concurrency code.

**Important:** `.serialized` only affects parameterized tests. It tells Swift Testing to run a test's argument cases one at a time rather than in parallel. Applying `.serialized` to a non-parameterized test does nothing. Applying it to a whole suite only serializes the parameterized tests inside that suite; other tests are unaffected.

Agents frequently assume `.serialized` works on any test. It does not.

```swift
@Test(.serialized, arguments: ["alice", "bob", "charlie"])
func userCreation(username: String) async throws {
    let user = try await UserService().create(username: username)
    #expect(user.isActive)
}
```


## Confirmation for async events

When testing that an async event fires (callback, notification, stream value), use `confirmation()`:

```swift
@Test func notificationFires() async {
    await confirmation { confirmed in
        // Start listening before posting, and yield to ensure the for-await
        // loop is actually iterating before the notification is sent. Without
        // the yield, the post can arrive before the listener is ready, making
        // the test flaky.
        let task = Task {
            for await _ in NotificationCenter.default.notifications(named: .dataDidChange) {
                confirmed()
                break
            }
        }

        // Give the task a chance to reach its first suspension.
        await Task.yield()

        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        await task.value
    }
}
```

`confirmation()` fails the test if the closure is never called, replacing the old XCTest pattern of `XCTestExpectation` + `wait(for:timeout:)`.

**Important:** All async work being confirmed must complete before the `confirmation()` closure returns. If the code under test spawns an internal `Task` and the test cannot await it, `confirmation()` will finish before the work does and the test will fail. Either make the production API `async` so the test can await it directly, or have it return its `Task` handle so the test can call `await task.value` before the closure ends.


## Actor isolation in tests

By default, Swift Testing runs tests on any executor it chooses. Constrain this when testing code that requires specific actor isolation:

```swift
@MainActor
@Test func viewModelUpdatesOnMainActor() async {
    let vm = ViewModel()
    await vm.refresh()
    #expect(vm.items.isEmpty == false)
}
```

For finer control, `confirmation()` and `withKnownIssue()` accept an `isolation` parameter — that closure runs on a specific actor while the rest of the test runs elsewhere:

```swift
@Test func loadingUpdatesUI() async {
    await confirmation(isolation: MainActor.shared) { confirmed in
        let vm = ViewModel(onUpdate: { confirmed() })
        await vm.load()
    }
}
```

Test targets can have default actor isolation enabled at the module level. When reviewing test failures around isolation, check the target's build settings.


## Test scoping traits with `@TaskLocal`

**Requires Swift 6.1 or later.**

When multiple tests need a shared configuration (mock environment, injected dependency), test scoping traits provide a concurrency-safe way to set it up using task-local values rather than shared mutable state.

Create a type conforming to `TestTrait` and `TestScoping`, then set the task-local value inside `provideScope()`:

```swift
struct MockEnvironmentTrait: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let env = Environment(apiBase: URL(string: "https://test.example.com")!)

        try await Environment.$current.withValue(env) {
            try await function()
        }
    }
}

extension Trait where Self == MockEnvironmentTrait {
    static var mockEnvironment: Self { Self() }
}
```

Apply it to any test or suite:

```swift
@Test(.mockEnvironment) func fetchUsesTestAPI() async throws {
    // Environment.current is now the mock, scoped to this test's task.
    let users = try await UserService().fetchAll()
    #expect(users.isEmpty == false)
}
```

This avoids the concurrency hazards of a shared `setUp()` mutating global state. Each test's configuration lives in the task-local, so parallel tests get independent values automatically.

### Async teardown via scoping trait

Because `deinit` cannot call async methods, scoping traits are the preferred pattern for async cleanup:

```swift
struct DatabaseTrait: SuiteTrait, TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let database = Database()
        try await Environment.$database.withValue(database) {
            await database.prepare()
            try await function()
            await database.cleanup() // Async teardown
        }
    }
}

@Suite(DatabaseTrait())
struct DatabaseTests {
    @Test func insertsData() async throws {
        try await Environment.database.insert(item)
    }
}
```


## Avoid timing-based tests

Never use `Task.sleep`, `Thread.sleep`, or fixed delays to "wait for something to happen." These tests are flaky — they may pass on fast machines but fail under load or on CI.

```swift
// BROKEN: relies on timing.
@Test func dataLoads() async throws {
    viewModel.load()
    try await Task.sleep(for: .seconds(1))
    #expect(viewModel.items.isEmpty == false)
}
```

Instead, await the actual async operation:

```swift
// CORRECT: awaits the real work.
@Test func dataLoads() async throws {
    await viewModel.load()
    #expect(viewModel.items.isEmpty == false)
}
```

If the API is callback-based, wrap it with `withCheckedContinuation` or use `confirmation()`.


## Testing cancellation

The goal is to verify that the *code under test* checks for cancellation, not just that `Task.checkCancellation()` works in a test harness. Design the test so the code under test is the thing that observes the cancellation flag.

Give the code under test a stream or signal it blocks on, cancel the task while it's suspended on that signal, then verify it exits with `CancellationError`:

```swift
@Test func processorRespectsCancel() async throws {
    // Processor.run() calls Task.checkCancellation() between items.
    let processor = Processor(items: Array(repeating: .stub, count: 1_000))

    let task = Task {
        try await processor.run()
    }

    // Let the processor start, then cancel.
    try await Task.sleep(for: .zero)
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}
```

If the code under test is a `for await` loop, cancel the consuming task and verify the loop exits. Key point: the test must exercise a cancellation check that lives in production code, not one you added to the test itself.


## Controlling execution with `withMainSerialExecutor`

Some tests need to observe intermediate state (e.g. `isLoading == true` during a fetch). Without serial execution, the task often races to completion before the assertion runs:

```swift
// Flaky — may pass or fail
@Test @MainActor func isLoadingState() async throws {
    let fetcher = ImageFetcher()
    let task = Task { try await fetcher.fetch(url) }
    #expect(fetcher.isLoading == true)  // Race
    try await task.value
    #expect(fetcher.isLoading == false)
}
```

With [swift-concurrency-extras](https://github.com/pointfreeco/swift-concurrency-extras), `withMainSerialExecutor` forces tasks to run serially on the main executor, making intermediate-state tests deterministic:

```swift
import ConcurrencyExtras

@Test @MainActor func isLoadingState() async throws {
    try await withMainSerialExecutor {
        let fetcher = ImageFetcher { url in
            await Task.yield()   // Allow test to observe state
            return Data()
        }

        let task = Task { try await fetcher.fetch(url) }
        await Task.yield()

        #expect(fetcher.isLoading == true)
        try await task.value
        #expect(fetcher.isLoading == false)
    }
}
```

Mark suites that rely on this with `.serialized` — the main serial executor does not coexist with parallel test execution. Only introduce this dependency when deterministic interleaving is genuinely required; prefer awaiting the real async operation.


## Testing memory management

Verify deallocation to catch retain cycles early.

The object can outlive the last `await` for a moment. When the awaited call ran a `Task` that held the object, the finished task can release it after the awaiting code has already resumed. This shows mostly when the thread pool is busy, as in parallel test runs and on CI. Capturing `[weak self]` in that task makes it rarer but does not close the window. Poll the weak reference until a deadline instead of checking it at once or after a fixed sleep, using the project's polling helper when it has one. A real retain cycle still fails at the deadline.

```swift
@Test func viewModelDeallocates() async throws {
    var viewModel: ViewModel? = ViewModel()
    weak let weakViewModel = viewModel

    await viewModel?.stop()
    viewModel = nil

    let deadline = ContinuousClock.now + .seconds(2)
    while weakViewModel != nil, ContinuousClock.now < deadline {
        await Task.yield()
    }
    #expect(weakViewModel == nil)
}
```


## Race detection

Enable Thread Sanitizer (TSan) in your test scheme to catch data races at runtime. TSan finds races that compiler static checks often miss, particularly in code using `@unchecked Sendable` or unsafe pointers.

In Xcode: Product → Scheme → Edit Scheme → Diagnostics → Thread Sanitizer.

TSan adds overhead — enable it for a dedicated CI job rather than every local run.


## XCTest legacy patterns

If the project still has XCTest concurrency tests and full migration isn't feasible:

```swift
final class ArticleSearcherTests: XCTestCase {
    @MainActor
    func testEmptyQuery() async {
        let searcher = ArticleSearcher()
        await searcher.search("")
        XCTAssertEqual(searcher.results, ArticleSearcher.allArticles)
    }

    @MainActor
    func testSearchTask() async {
        let searcher = ArticleSearcher()
        let expectation = expectation(description: "Search complete")

        _ = withObservationTracking {
            searcher.results
        } onChange: {
            expectation.fulfill()
        }

        searcher.startSearchTask("swift")

        // Use fulfillment, not wait — wait(for:) deadlocks in async contexts.
        await fulfillment(of: [expectation], timeout: 10)
        XCTAssertEqual(searcher.results.count, 1)
    }
}
```

Setup/teardown can be async:

```swift
override func setUp() async throws { /* async setup */ }
override func tearDown() async throws { /* async teardown */ }
```


## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Test hangs | Waiting for an expectation/confirmation that never fires | Add timeout; verify the observation or confirmation path actually runs |
| Flaky test | Race condition in unstructured task | Use `withMainSerialExecutor` + `Task.yield()`, or restructure the API to be awaitable |
| Deadlock | Using `wait(for:)` in an async context | Use `await fulfillment(of:)` instead |
| Confirmation fails | Not awaiting async work before confirmation closure exits | Make the production API `async` or return its `Task` handle and `await task.value` |
| Actor isolation error in test | Test not marked with required actor | Add `@MainActor` (or appropriate actor) to the test |


## Swift Testing + Swift concurrency checklist

- Tests marked with correct isolation.
- Async methods properly awaited.
- Cancellation tested against real production cancellation checks.
- Memory leak checks for long-lived managers.
- Race conditions controlled with `withMainSerialExecutor` only when intermediate state must be observed.
- No fixed-delay `Task.sleep` used as synchronization.
- Thread Sanitizer enabled on a dedicated CI job.

For help with Swift Testing itself, use the [`swift-testing`](../../swift-testing/SKILL.md) skill.
