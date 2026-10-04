---
name: swift-testing
description: Expert guidance on Swift Testing for writing, reviewing, migrating, and debugging tests. Use when developers mention Swift Testing, @Test, @Suite, #expect, #require, traits and tags, parameterized tests, parallel execution, async waiting, XCTest migration, test doubles, fixtures, integration tests, snapshot tests, F.I.R.S.T. principles, Arrange-Act-Assert, or test plan filtering.
license: MIT
---

Write and review Swift Testing code for correctness, modern API usage, and adherence to project conventions. Report only genuine problems — do not nitpick or invent issues.


## First 60 seconds (triage template)

Before diving in, clarify the goal and collect minimal facts:

- Goal: new tests, migration, flaky failures, performance, CI filtering, or async waiting?
- Xcode/Swift version and platform targets
- Tests currently using XCTest, Swift Testing, or both?
- Failures deterministic or flaky?
- Tests accessing shared resources (database, files, network, global state)?

Branch quickly:

- Repetitive tests → parameterized tests ([references/parameterized-tests.md](references/parameterized-tests.md))
- Noisy or flaky failures → known-issue handling and test isolation ([references/parallelization-and-isolation.md](references/parallelization-and-isolation.md))
- Migration questions → XCTest mapping and coexistence ([references/migrating-from-xctest.md](references/migrating-from-xctest.md))
- Async callback complexity → continuation / confirmation patterns ([references/async-tests.md](references/async-tests.md))


## Review process

1. Ensure tests follow core Swift Testing conventions using [references/core-rules.md](references/core-rules.md) and [references/fundamentals.md](references/fundamentals.md).
2. Validate test structure, assertions, dependency injection, and hygiene using [references/writing-better-tests.md](references/writing-better-tests.md) and [references/expectations.md](references/expectations.md).
3. Validate traits, tags, and test-plan filtering using [references/traits-and-tags.md](references/traits-and-tags.md).
4. Check parallel execution and isolation using [references/parallelization-and-isolation.md](references/parallelization-and-isolation.md).
5. Check parameterized tests using [references/parameterized-tests.md](references/parameterized-tests.md).
6. Check async tests, confirmations, time limits, actor isolation, networking mocks, cancellation, and callback bridging using [references/async-tests.md](references/async-tests.md).
7. Check performance, determinism, and flakiness prevention using [references/performance-and-best-practices.md](references/performance-and-best-practices.md).
8. Ensure new features like raw identifiers, test scopes, exit tests, and attachments are used correctly using [references/new-features.md](references/new-features.md).
9. For Xcode workflows (test navigator, reports, diagnostics) use [references/xcode-workflows.md](references/xcode-workflows.md).
10. For test organization (nested suites, tags, shared setup) use [references/test-organization.md](references/test-organization.md).
11. For fixtures and test doubles (dummies, fakes, stubs, spies, mocks), see [references/fixtures.md](references/fixtures.md) and [references/test-doubles.md](references/test-doubles.md).
12. For multi-module/integration tests, see [references/integration-testing.md](references/integration-testing.md).
13. For UI/data-structure snapshot tests, see [references/snapshot-testing.md](references/snapshot-testing.md) and [references/dump-snapshot-testing.md](references/dump-snapshot-testing.md).
14. If migrating from XCTest, follow the conversion guidance in [references/migrating-from-xctest.md](references/migrating-from-xctest.md).

If doing partial work, load only the relevant reference files.


## Core Instructions

- Target Swift 6.2 or later, using modern Swift concurrency.
- Prefer Swift Testing for all new unit and integration tests; help migrate existing XCTest code when asked.
- Swift Testing does **not** support UI tests — keep `XCUIApplication` on XCTest. Also keep `XCTMetric` performance tests and Objective-C-only test code on XCTest.
- Only import `Testing` in test targets, never in app/library/binary targets.
- Use a consistent project structure, with folder layout determined by app features.
- Treat `#expect` as the default assertion; use `#require` when subsequent lines depend on a prerequisite value or when you need hard-stop semantics.
- Default to parallel-safe guidance. If tests are not isolated, first propose fixing shared state before applying `.serialized`.
- Prefer traits for behavior and metadata (`.enabled`, `.disabled`, `.timeLimit`, `.bug`, tags) over naming conventions or ad-hoc comments.
- Recommend parameterized tests when multiple tests share logic and differ only in input values.
- Use `@available` on test functions for OS-gated behavior instead of runtime `#available` checks inside test bodies; never annotate suite types with `@available`.
- Keep migration advice incremental: convert assertions first, then organize suites, then introduce parameterization/traits.

Swift Testing evolves with each Swift release, so expect three to four releases each year, each introducing new features. Training data will naturally be outdated. Treat the user's installed toolchain as authoritative, but note that Apple's documentation about the APIs is often stale — handle it carefully.


## Agent Behavior Contract

1. Use Swift Testing framework (`@Test`, `#expect`, `#require`, `@Suite`) for all new tests, not XCTest.
2. Always structure tests with clear Arrange-Act-Assert phases.
3. Follow F.I.R.S.T. principles: Fast, Isolated, Repeatable, Self-Validating, Timely.
4. Use proper test double terminology per Martin Fowler's taxonomy (Dummy, Fake, Stub, Spy, SpyingStub, Mock). What the Swift community often calls a "Mock" is usually a **SpyingStub**.
5. Place fixtures close to models with `#if DEBUG`, not in test targets.
6. Place test doubles close to interfaces with `#if DEBUG`, not in test targets.
7. Prefer state verification over behavior verification — simpler, less brittle tests.
8. Use `#expect` for soft assertions (continue on failure) and `#require` for hard assertions (stop on failure).


## F.I.R.S.T. Principles

| Principle | Description | Application |
|-----------|-------------|-------------|
| **Fast** | Tests execute in milliseconds | Mock expensive operations |
| **Isolated** | Tests don't depend on each other | Fresh instance per test |
| **Repeatable** | Same result every time | Mock dates, network, external deps |
| **Self-Validating** | Auto-report pass/fail | Use `#expect`, never rely on `print()` |
| **Timely** | Write tests alongside code | Use parameterized tests for edge cases |


## Test Double Quick Reference

Per [Martin Fowler's taxonomy](https://martinfowler.com/articles/mocksArentStubs.html):

| Type | Purpose | Verification |
|------|---------|--------------|
| **Dummy** | Fill parameters, never used | N/A |
| **Fake** | Working implementation with shortcuts | State |
| **Stub** | Provides canned answers | State |
| **Spy** | Records calls for verification | State |
| **SpyingStub** | Stub + Spy combined (most common) | State |
| **Mock** | Pre-programmed expectations, self-verifies | Behavior |

Place doubles close to the interface they implement, not in test targets:

```swift
public protocol RepositoryProtocol: Sendable {
    func getAll() async throws -> [Record]
    func save(_ record: Record) async throws
}

#if DEBUG
public final class RepositorySpyingStub: RepositoryProtocol {
    // Spy: captured calls
    public private(set) var savedRecords: [Record] = []

    // Stub: configurable responses
    public var recordsToReturn: [Record] = []
    public var errorToThrow: Error?

    public func getAll() async throws -> [Record] {
        if let errorToThrow { throw errorToThrow }
        return recordsToReturn
    }

    public func save(_ record: Record) async throws {
        if let errorToThrow { throw errorToThrow }
        savedRecords.append(record)
    }
}
#endif
```

Place fixtures next to the model with `#if DEBUG` guards:

```swift
#if DEBUG
extension Record {
    public static func fixture(
        id: UUID = UUID(),
        value: Double = 100.0
    ) -> Record {
        Record(id: id, value: value)
    }
}
#endif
```

For full patterns see [references/test-doubles.md](references/test-doubles.md) and [references/fixtures.md](references/fixtures.md).


## Test Pyramid

```
        +-------------+
        |   UI Tests  |  5%  - End-to-end flows
        |   (E2E)     |
        +-------------+
        | Integration |  15% - Module interactions
        |    Tests    |
        +-------------+
        |    Unit     |  80% - Individual components
        |    Tests    |
        +-------------+
```


## Arrange-Act-Assert Pattern

Structure every test with clear phases:

```swift
@Test func calculateTotal() {
    // Given
    let cart = ShoppingCart()
    cart.add(Item(price: 10))
    cart.add(Item(price: 20))

    // When
    let total = cart.calculateTotal()

    // Then
    #expect(total == 30)
}
```


## Common pitfalls → next best move

- Repetitive `testFooCaseA/testFooCaseB/...` methods → one parameterized `@Test(arguments:)`.
- Failing optional preconditions hidden in later assertions → `try #require(...)` then assert on the unwrapped value.
- Flaky integration tests on shared database → isolate dependencies or use in-memory repositories; use `.serialized` only as a transition step.
- Disabled tests that silently rot → prefer `withKnownIssue` for temporary known failures to preserve signal.
- Unclear failure values for complex types → conform the type to `CustomTestStringConvertible` for focused diagnostics.
- Test-plan include/exclude by names → use tags and tag-based filters instead.
- `.serialized` is scope-dependent: on a bare non-parameterized `@Test func` it has no effect; on a parameterized `@Test` it serializes the argument cases; on `@Suite(.serialized)` it serializes all the suite's contained tests (parameterized or not) and sub-suites relative to each other. See `references/async-tests.md`.
- `.timeLimit(.seconds(...))` → only `.minutes(...)` is accepted.
- Unsafe mutable counters captured by async callbacks → use an actor or thread-safe container.
- `#require` nested inside another `#require`'s argument → fails to compile with "recursive expansion of macro 'require(_:_:sourceLocation:)'"; bind the inner `try #require(...)` to a local first. `#require` inside `#expect` (`#expect(try #require(optional).count == 1)`) compiles with Swift 6.4, and a single macro nested inside an ordinary call (`Foo(bar: #require(x))`) is fine.
- Key-path argument to a rethrowing call that is the whole `#expect`/`#require` condition (`#expect(!s.contains(where: \.isNumber))`) → fails macro expansion with "call can throw, but it is not marked with 'try' and the error is not handled"; pass a closure instead (`#expect(!s.contains { $0.isNumber })`) or bind the result to a local first.


## Verification checklist

- Each test has a single clear behavior and an expressive display name where needed.
- Prerequisites use `#require` where failure should stop the test.
- Repeated logic is parameterized instead of duplicated.
- Tests are parallel-safe or intentionally serialized with rationale.
- Async code is awaited and callback APIs are bridged safely.
- Fixtures use sensible defaults, not random values.
- Test doubles are minimal (only stub what's needed).
- Migration preserves XCTest-only scenarios (UI, `XCTMetric`, ObjC-only) on XCTest.


## Output Format

If the user asks for a review, organize findings by file. For each issue:

1. State the file and relevant line(s).
2. Name the rule being violated.
3. Show a brief before/after code fix.

Skip files with no issues. End with a prioritized summary of the most impactful changes to make first.

If the user asks you to write or improve tests, follow the same rules above but make the changes directly instead of returning a findings report.

Example output:

### UserTests.swift

**Line 5: Use struct, not class, for test suites.**

```swift
// Before
class UserTests: XCTestCase {

// After
struct UserTests {
```

**Line 12: Use `#expect` instead of `XCTAssertEqual`.**

```swift
// Before
XCTAssertEqual(user.name, "Taylor")

// After
#expect(user.name == "Taylor")
```

**Line 30: Use `#require` for preconditions, not `#expect`.**

```swift
// Before
#expect(users.isEmpty == false)
let first = users.first!

// After
let first = try #require(users.first)
```

### Summary

1. **Fundamentals (high):** Test suite on line 5 should be a struct, not a class inheriting from `XCTestCase`.
2. **Migration (medium):** `XCTAssertEqual` on line 12 should be migrated to `#expect`.
3. **Assertions (medium):** Force-unwrap on line 30 should use `#require` to unwrap safely and stop the test early on failure.

End of example.


## References

### Core

- [references/core-rules.md](references/core-rules.md) — core Swift Testing rules: structs over classes, `init`/`deinit` over setUp/tearDown, parallel execution, parameterized tests, `withKnownIssue`, tags.
- [references/fundamentals.md](references/fundamentals.md) — test building blocks and suite organization.
- [references/writing-better-tests.md](references/writing-better-tests.md) — test hygiene, structuring, hidden dependencies, `#expect` vs `#require`, `Issue.record()`, `#expect(throws:)`, verification methods.
- [references/expectations.md](references/expectations.md) — `#expect`, `#require`, and throw expectations.
- [references/new-features.md](references/new-features.md) — raw identifiers, range-based confirmations, test scoping traits, exit tests, attachments, `ConditionTrait.evaluate()`, updated `#expect(throws:)` return value.

### Organization & Traits

- [references/test-organization.md](references/test-organization.md) — suites, tags, nested suites, parallel execution.
- [references/traits-and-tags.md](references/traits-and-tags.md) — traits, tags, and Xcode test-plan filtering.
- [references/parallelization-and-isolation.md](references/parallelization-and-isolation.md) — default parallel execution, `.serialized`, isolation strategy.

### Parameterized tests

- [references/parameterized-tests.md](references/parameterized-tests.md) — testing multiple inputs efficiently, parameterized test design, and combinatorics.

### Async & performance

- [references/async-tests.md](references/async-tests.md) — serialized tests, `confirmation()`, time limits, actor isolation, pre-concurrency code, networking mocks, cancellation, callback bridging, legacy-waiting anti-patterns.
- [references/chunked-parallel-mock-drain.md](references/chunked-parallel-mock-drain.md) — drain mock outboxes one stanza at a time when the system under test fans out via `stride`-chunked `withTaskGroup`; `waitForSent(count: N)` deadlocks at chunk boundaries.
- [references/performance-and-best-practices.md](references/performance-and-best-practices.md) — test speed, determinism, flakiness prevention.

### Test doubles & fixtures

- [references/test-doubles.md](references/test-doubles.md) — full Fowler taxonomy (Dummy, Fake, Stub, Spy, SpyingStub, Mock) with examples.
- [references/fixtures.md](references/fixtures.md) — fixture patterns, placement, best practices.

### Integration & snapshot

- [references/integration-testing.md](references/integration-testing.md) — module interaction testing patterns.
- [references/integration-suite-patterns.md](references/integration-suite-patterns.md) — cross-suite serialization, nested `@Suite` enums for layered test targets, `swift test --filter` regex semantics, async teardown without `defer`, credential gating.
- [references/snapshot-testing.md](references/snapshot-testing.md) — UI regression testing with SnapshotTesting library.
- [references/dump-snapshot-testing.md](references/dump-snapshot-testing.md) — text-based snapshot testing for data structures.

### Migration & workflows

- [references/migrating-from-xctest.md](references/migrating-from-xctest.md) — XCTest-to-Swift Testing conversion steps, assertion mappings, coexistence, test-plan strategy, floating-point tolerance via Swift Numerics.
- [references/xcode-workflows.md](references/xcode-workflows.md) — test navigator/report workflows and diagnostics.
