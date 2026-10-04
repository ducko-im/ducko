import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoCore

enum LinkPreviewServiceTests {
    struct CachedPreview {
        @Test
        func `Returns nil for uncached URL`() {
            let store = MockPersistenceStore()
            let service = LinkPreviewService(fetcher: NoOpLinkPreviewFetcher(), store: store)

            let result = service.cachedPreview(for: "https://example.com")
            #expect(result == nil)
        }

        @Test
        func `Returns cached preview after fetch`() async throws {
            let store = MockPersistenceStore()
            let fetcher = StubLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)

            let url = try #require(URL(string: "https://example.com"))
            _ = try await service.fetchPreview(for: url)

            let result = service.cachedPreview(for: "https://example.com")
            #expect(result != nil)
            #expect(result?.title == "Stub Title")
        }

        @Test
        func `A repeat fetch for a cached URL skips the fetcher`() async throws {
            let store = MockPersistenceStore()
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let url = try #require(URL(string: "https://example.com"))

            _ = try await service.fetchPreview(for: url)
            let second = try await service.fetchPreview(for: url)

            // The second call resolves from the cache (Resolution.cached) — no second fetch.
            #expect(second != nil)
            #expect(await fetcher.invocationCount == 1)
        }

        @Test
        func `A persisted preview is returned without invoking the fetcher`() async throws {
            let store = MockPersistenceStore()
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let url = try #require(URL(string: "https://example.com"))
            try await store.upsertLinkPreview(LinkPreview(
                url: url.absoluteString, title: "Persisted", descriptionText: "d", siteName: "s", fetchedAt: Date()
            ))

            let result = try await service.fetchPreview(for: url)

            // The store hit returns before the fetcher/limiter is ever reached.
            #expect(result?.title == "Persisted")
            #expect(await fetcher.invocationCount == 0)
        }
    }

    struct StoredPreview {
        @Test
        func `A persisted preview is returned and cached without invoking the fetcher`() async throws {
            let store = MockPersistenceStore()
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let link = "https://example.com/page"
            try await store.upsertLinkPreview(LinkPreview(url: link, title: "Stored", fetchedAt: Date()))

            let preview = await service.storedPreview(for: link)

            #expect(preview?.title == "Stored")
            #expect(service.cachedPreview(for: link)?.title == "Stored")
            #expect(await fetcher.invocationCount == 0)
        }

        @Test
        func `An unknown URL has no stored preview and is not fetched`() async {
            let fetcher = CountingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: MockPersistenceStore())

            let preview = await service.storedPreview(for: "https://example.com/unknown")

            #expect(preview == nil)
            #expect(await fetcher.invocationCount == 0)
        }
    }

    struct Coalescing {
        @Test
        func `Concurrent fetches for the same URL share one fetch`() async throws {
            let store = MockPersistenceStore()
            let fetcher = SpyingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let url = try #require(URL(string: "https://example.com"))

            // Start the first fetch and let it enter (and block inside) the fetcher, so its in-flight entry is
            // stored before the second caller reads it.
            let first = Task { try await service.fetchPreview(for: url) }
            #expect(await pollUntil({ await fetcher.invocationCount >= 1 }, timeout: .seconds(5)))

            // The second caller coalesces onto the still-blocked in-flight fetch rather than starting its own.
            let second = Task { try await service.fetchPreview(for: url) }
            for _ in 0 ..< 5 {
                await Task.yield()
            }

            await fetcher.release()

            let firstResult = try await first.value
            let secondResult = try await second.value
            #expect(firstResult != nil)
            #expect(secondResult != nil)
            #expect(await fetcher.invocationCount == 1)
        }
    }

    struct FailedFetchRetry {
        @Test
        func `A thrown fetch is not cached and a later call retries`() async throws {
            let store = MockPersistenceStore()
            let fetcher = FlakyLinkPreviewFetcher(mode: .failure)
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let url = try #require(URL(string: "https://example.com"))

            await #expect(throws: (any Error).self) {
                _ = try await service.fetchPreview(for: url)
            }

            // The failed fetch cleared its in-flight entry and cached nothing, so a retry re-invokes the fetcher.
            await fetcher.setMode(.success)
            let result = try await service.fetchPreview(for: url)
            #expect(result != nil)
            #expect(await fetcher.invocationCount == 2)
        }

        @Test
        func `A nil result is not cached and a later call retries`() async throws {
            let store = MockPersistenceStore()
            let fetcher = FlakyLinkPreviewFetcher(mode: .empty)
            let service = LinkPreviewService(fetcher: fetcher, store: store)
            let url = try #require(URL(string: "https://example.com"))

            let first = try await service.fetchPreview(for: url)
            #expect(first == nil)

            await fetcher.setMode(.success)
            let second = try await service.fetchPreview(for: url)
            #expect(second != nil)
            #expect(await fetcher.invocationCount == 2)
        }
    }

    struct ConcurrencyCap {
        @Test
        func `No more than maxConcurrentFetches run at once`() async throws {
            let store = MockPersistenceStore()
            let fetcher = SpyingLinkPreviewFetcher()
            let service = LinkPreviewService(fetcher: fetcher, store: store, maxConcurrentFetches: 2)

            let tasks = (0 ..< 6).map { index in
                Task { try await service.fetchPreview(for: URL(string: "https://example.com/\(index)")!) }
            }

            // Exactly the cap reaches the (blocked) fetcher; the rest wait on the limiter's permits.
            #expect(await pollUntil({ await fetcher.invocationCount >= 2 }, timeout: .seconds(5)))
            await fetcher.release()

            for task in tasks {
                _ = try await task.value
            }
            #expect(await fetcher.maxObservedConcurrency == 2)
            #expect(await fetcher.invocationCount == 6)
        }
    }
}

private struct StubLinkPreviewFetcher: LinkPreviewFetcher {
    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        LinkPreview(
            url: url.absoluteString,
            title: "Stub Title",
            descriptionText: "A description",
            siteName: "example.com",
            fetchedAt: Date()
        )
    }
}

/// Fetcher whose result mode can be switched between calls, so the failed-fetch/nil-then-retry cleanup can be
/// asserted (a failure must neither cache nor block a later retry).
private actor FlakyLinkPreviewFetcher: LinkPreviewFetcher {
    enum Mode { case failure, empty, success }

    private(set) var invocationCount = 0
    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
    }

    struct FetchError: Error {}

    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        invocationCount += 1
        switch mode {
        case .failure:
            throw FetchError()
        case .empty:
            return nil
        case .success:
            return LinkPreview(
                url: url.absoluteString,
                title: "Retry Title",
                descriptionText: "A description",
                siteName: "example.com",
                fetchedAt: Date()
            )
        }
    }
}

/// Counts invocations, tracks peak concurrency, and blocks every call at a gate until `release()`, so
/// coalescing and the concurrency cap can be asserted deterministically without sleeps.
private actor SpyingLinkPreviewFetcher: LinkPreviewFetcher {
    private(set) var invocationCount = 0
    private(set) var maxObservedConcurrency = 0
    private var active = 0
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func fetchPreview(for url: URL) async throws -> LinkPreview? {
        invocationCount += 1
        active += 1
        maxObservedConcurrency = max(maxObservedConcurrency, active)
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        active -= 1
        return LinkPreview(
            url: url.absoluteString,
            title: "Spy Title",
            descriptionText: "A description",
            siteName: "example.com",
            fetchedAt: Date()
        )
    }
}
