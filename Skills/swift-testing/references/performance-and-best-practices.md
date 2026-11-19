# Performance and Best Practices

## When to use this reference

Use this file when test runs are slow, flaky, or not scaling in CI, and when you need practical patterns for fast, deterministic Swift Testing suites.

## Core principles

- Prefer deterministic tests over timing-sensitive tests.
- Prefer synchronous verification when asynchronous waiting is not required.
- Keep tests independent so parallel execution remains safe and effective.
- Treat `.serialized` as a temporary compromise, not a default architecture.

## 1) Keep tests synchronous where possible

Synchronous tests generally run faster and are easier to reason about.

```swift
import Testing

struct PriceCalculator {
 static func total(_ subtotal: Int, discount: Int) -> Int { subtotal - discount }
}

@Test func totalCalculation() {
 #expect(PriceCalculator.total(100, discount: 20) == 80)
}
```

Avoid introducing `async` or sleeps for purely synchronous logic.

```swift
// Avoid:
// @Test func totalCalculation() async {
//   try await Task.sleep(nanoseconds: 100_000_000)
//   #expect(...)
// }
```

## 2) Avoid unnecessary main-actor isolation

`@MainActor` can reduce useful parallelization and should be used only when code truly needs main-thread isolation.

```swift
import Testing

// Good: non-UI logic stays non-main-actor.
@Test func parserIsStable() {
 #expect("A,B,C".split(separator: ",").count == 3)
}

// Use @MainActor only for UI/main-thread sensitive code.
@MainActor
@Test func viewModelMutation() {
 #expect(true)
}
```

## 3) Remove shared mutable state

Shared mutable state is a major source of flakiness and parallel failures.

```swift
import Testing

enum Globals {
 static var token: String?
}

// Flaky pattern:
@Test func writeToken() {
 Globals.token = "abc"
 #expect(Globals.token == "abc")
}

@Test func expectsNoToken() {
 #expect(Globals.token == nil)
}
```

Better: create isolated state per test.

```swift
import Testing

struct SessionState {
 var token: String?
}

@Test func isolatedTokenState() {
 var state = SessionState()
 state.token = "abc"
 #expect(state.token == "abc")
}
```

## 4) Prefer in-memory dependencies for the fast path

Use fakes/in-memory repositories for high-volume test runs; reserve real integration dependencies for dedicated plans.

```swift
import Testing

protocol CacheStore {
 func put(key: String, value: String)
 func get(key: String) -> String?
}

final class InMemoryCacheStore: CacheStore {
 private var values: [String: String] = [:]
 func put(key: String, value: String) { values[key] = value }
 func get(key: String) -> String? { values[key] }
}

@Test func cacheRoundTrip() {
 let cache = InMemoryCacheStore()
 cache.put(key: "user", value: "42")
 #expect(cache.get(key: "user") == "42")
}
```

## 5) Use parameterized tests to reduce overhead and improve diagnostics

```swift
import Testing

func isValidPort(_ value: Int) -> Bool { (1...65535).contains(value) }

@Test(arguments: [1, 80, 443, 65535])
func validPorts(_ port: Int) {
 #expect(isValidPort(port))
}
```

This reduces duplicated setup code and gives argument-level failure visibility.

## 6) Keep setup cheap and scoped

- Build expensive fixtures only when needed.
- Prefer per-suite immutable setup for shared readonly data.
- Avoid network/file-system setup in unit tests unless behavior depends on it.

```swift
import Testing

struct CurrencyTests {
 let rates: [String: Double]

 init() {
 rates = ["USD": 1.0, "EUR": 0.92]
 }

 @Test func hasEURRate() {
 #expect(rates["EUR"] != nil)
 }
}
```

## 7) Use `.serialized` narrowly

`.serialized` is scope-dependent (see `async-tests.md`): `@Suite(.serialized)` serializes the suite's contained tests relative to each other, a parameterized `@Test` serializes its argument cases, and a bare non-parameterized function is unaffected. It is a coarse, suite-local guard — prefer isolating shared state, which survives tests being split across suites or run individually.

```swift
import Testing

// On a suite, `.serialized` keeps these tests from running concurrently.
@Suite(.serialized)
struct TemporarySerialDBTests {
 @Test func seedThenRead() async throws { #expect(try await seedAndRead()) }
 @Test func writeThenVerify() async throws { #expect(try await writeAndVerify()) }
}
```

Add TODO context and remove once dependencies are isolated.

## 8) Flakiness reduction checklist

- No reliance on execution order.
- No shared mutable globals/singletons without reset.
- No arbitrary sleeps as synchronization.
- No hidden external dependencies in unit tests.
- Deterministic fixtures and stable clocks/random sources.
- Explicit known-issue wrappers for temporary failures.

Reproduce a suspected flake before fixing it, and confirm the fix the same way: `swift test --filter <test or suite> --maximum-repetitions <N> --repeat-until fail`. SwiftPM has no `--repetitions` flag. A rare race may need thousands of repetitions, so count a fix only when far more repetitions pass than it took to reproduce the failure.

## 9) Measure before changing waits

- Measure per-test wall time from the runner's own `passed after N seconds` lines before changing any wait; rank suites by that, not by grepping for `Task.sleep`. Swift Testing runs tests in parallel by default, so a suspicious duration includes sibling contention; confirm it on a serialized run (`swift test --no-parallel`).
- When many tests cluster at the same round duration (0.5 s, 1 s, 1.5 s), suspect a timeout in the code under test that the test double never answers: a teardown handshake, a sync ack, a close reply. Test-side sleeps of a few hundred milliseconds rarely add up to the observed total.
- Fix it at the double or the seam: make the double answer as a compliant peer would, or expose the timeout as a parameter the test shortens. Leave sleeps and timeouts that assert absence, expiry, or elapsed time in place.
- Measure with nothing else building or testing on the machine; a concurrent run inflates bounded waits and turns timing-sensitive tests flaky.

## Quick do / don't

- Do optimize for determinism first, then speed.
- Do keep most tests parallel-safe and dependency-light.
- Don't treat test slowness as only a hardware problem.
- Don't move everything to `@MainActor` or `.serialized` to silence flakiness.
