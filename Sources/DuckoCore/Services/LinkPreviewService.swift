import Foundation
import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.core.linkpreview")

public final class LinkPreviewService: Sendable {
    /// Result cache plus the in-flight fetches keyed by URL. Coalescing the in-flight map means two concurrent
    /// first-reads of the same URL share one fetch instead of both hitting the network.
    private struct State {
        var cache: [String: LinkPreview] = [:]
        var inFlight: [String: Task<LinkPreview?, Error>] = [:]
    }

    private let fetcher: any LinkPreviewFetcher
    private let store: any PersistenceStore
    private let state: OSAllocatedUnfairLock<State>
    private let limiter: ConcurrencyLimiter

    /// `maxConcurrentFetches` is deliberately conservative: `LPMetadataProvider` is heavyweight, and a bulk
    /// history load can detect many URLs at once, so the cap keeps that burst bounded regardless of origin.
    public init(fetcher: any LinkPreviewFetcher, store: any PersistenceStore, maxConcurrentFetches: Int = 4) {
        self.fetcher = fetcher
        self.store = store
        self.state = OSAllocatedUnfairLock(initialState: State())
        self.limiter = ConcurrencyLimiter(limit: maxConcurrentFetches)
    }

    public func cachedPreview(for urlString: String) -> LinkPreview? {
        state.withLock { $0.cache[urlString] }
    }

    /// The preview already fetched for `urlString`, from memory or from the store. Never fetches one.
    public func storedPreview(for urlString: String) async -> LinkPreview? {
        if let cached = cachedPreview(for: urlString) { return cached }
        guard let persisted = try? await store.fetchLinkPreview(for: urlString) else { return nil }
        state.withLock { $0.cache[urlString] = persisted }
        return persisted
    }

    private enum Resolution {
        case cached(LinkPreview)
        case inFlight(Task<LinkPreview?, Error>)
    }

    public func fetchPreview(for url: URL) async throws -> LinkPreview? {
        let key = url.absoluteString

        // Resolve cache/in-flight/create under one lock acquisition. Rechecking the cache here (not only before
        // the lock) closes the window where a peer fetch completes and caches between a caller's pre-lock miss
        // and its in-flight read — which would otherwise spawn a redundant task for an already-cached URL.
        let resolution: Resolution = state.withLock { state in
            if let cached = state.cache[key] {
                return .cached(cached)
            }
            if let existing = state.inFlight[key] {
                return .inFlight(existing)
            }
            let task = Task<LinkPreview?, Error> {
                try await self.loadPreview(for: url, key: key)
            }
            state.inFlight[key] = task
            return .inFlight(task)
        }

        switch resolution {
        case let .cached(preview):
            return preview
        case let .inFlight(task):
            return try await task.value
        }
    }

    /// Runs once per key via `fetchPreview`'s coalescing. Removes its own `inFlight` entry on every exit (success,
    /// nil, throw) so a failed fetch neither caches nor blocks a later retry. Only the network
    /// `fetcher.fetchPreview` consumes a permit; cache and persisted-store hits return without one.
    private func loadPreview(for url: URL, key: String) async throws -> LinkPreview? {
        defer { state.withLock { _ = $0.inFlight.removeValue(forKey: key) } }

        if let persisted = try await store.fetchLinkPreview(for: key) {
            state.withLock { $0.cache[key] = persisted }
            return persisted
        }

        guard let preview = try await limiter.withPermit({ try await self.fetcher.fetchPreview(for: url) }) else {
            return nil
        }

        do {
            try await store.upsertLinkPreview(preview)
        } catch {
            log.warning("Failed to persist link preview: \(error)")
        }
        state.withLock { $0.cache[key] = preview }

        return preview
    }
}
