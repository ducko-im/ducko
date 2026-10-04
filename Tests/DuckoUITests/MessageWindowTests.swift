import DuckoCore
import DuckoTestSupport
import Foundation
import Testing
@testable import DuckoUI

struct MessageWindowTests {
    private let conversationID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func message(at offset: TimeInterval, body: String = "") -> ChatMessage {
        ChatMessage(
            id: UUID(), conversationID: conversationID, fromJID: "bob@example.com", body: body,
            timestamp: start.addingTimeInterval(offset), isOutgoing: false, isDelivered: true, isEdited: false, type: "chat"
        )
    }

    /// One message per second, oldest first.
    private func messages(_ count: Int) -> [ChatMessage] {
        (0 ..< count).map { message(at: TimeInterval($0)) }
    }

    /// What `ChatService.fetchMessageHistory` returns: the store's newest matches, oldest first.
    private func fetch(_ store: MockTranscriptStore, before: Date?, limit: Int) async throws -> [ChatMessage] {
        try await store.fetchMessages(for: conversationID, before: before, limit: limit).reversed()
    }

    @Test func `messages sharing a second with a page boundary each show once`() async throws {
        let store = MockTranscriptStore()
        // Five messages share the second that the first page's boundary falls into.
        let boundary = TimeInterval(MessageWindow.pageSize)
        let stored = messages(MessageWindow.pageSize - 2)
            + (0 ..< 5).map { _ in message(at: boundary) }
            + (1 ... MessageWindow.pageSize - 3).map { message(at: boundary + TimeInterval($0)) }
        try await store.appendMessages(stored)

        var window = try #require(try await MessageWindow.olderPage(before: [], in: fetch(store, before: nil, limit: 2 * MessageWindow.pageSize)))
        // Armed: the boundary falls among the five.
        try #require(window.first?.timestamp == start.addingTimeInterval(boundary))
        try #require(stored[stored.count - window.count - 1].timestamp == start.addingTimeInterval(boundary))
        while window.count < stored.count {
            let oldest = try #require(window.first)
            let cutoff = oldest.timestamp.addingTimeInterval(1)
            let page = try #require(try await MessageWindow.olderPage(before: window, in: fetch(store, before: cutoff, limit: 2 * MessageWindow.pageSize)))
            try #require(!page.isEmpty)
            window = page + window
        }

        #expect(window.map(\.id) == stored.map(\.id))
    }

    @Test func `an empty window gets the newest page`() {
        let fetched = messages(MessageWindow.pageSize + 10)

        let page = MessageWindow.olderPage(before: [], in: fetched)

        #expect(page?.map(\.id) == fetched.suffix(MessageWindow.pageSize).map(\.id))
    }

    @Test func `there is no older page when the fetch does not hold the oldest loaded message`() {
        let fetched = messages(10)

        #expect(MessageWindow.olderPage(before: [message(at: 5)], in: fetched) == nil)
    }

    @Test func `a message appended in the oldest loaded one's second is newer, not older`() async throws {
        let store = MockTranscriptStore()
        let older = message(at: 0, body: "older")
        let loaded = message(at: 10, body: "A")
        let appended = message(at: 10, body: "B")
        try await store.appendMessages([older, loaded, appended])
        let fetched = try await fetch(store, before: loaded.timestamp.addingTimeInterval(1), limit: 2 * MessageWindow.pageSize)

        let page = MessageWindow.olderPage(before: [loaded], in: fetched)
        let refreshed = MessageWindow.refreshed(loaded: [loaded], reloaded: fetched, isAtNewest: true)

        #expect(page?.map(\.body) == ["older"])
        #expect(refreshed.map(\.body) == ["A", "B"])
    }

    @Test func `a refresh of an empty window is the newest initial count`() {
        let reloaded = messages(MessageWindow.initialCount + 20)

        let window = MessageWindow.refreshed(loaded: [], reloaded: reloaded, isAtNewest: true)

        #expect(window.map(\.id) == reloaded.suffix(MessageWindow.initialCount).map(\.id))
    }

    @Test func `a refresh that reaches the window's oldest message continues from it`() {
        let stored = messages(80)
        let loaded = Array(stored[20 ..< 60])

        let window = MessageWindow.refreshed(loaded: loaded, reloaded: Array(stored[10...]), isAtNewest: false)

        #expect(window.map(\.id) == stored[20...].map(\.id))
    }

    @Test func `a refresh that starts inside the window keeps what was loaded before it`() {
        let stored = messages(80)
        let loaded = Array(stored[..<60])

        let window = MessageWindow.refreshed(loaded: loaded, reloaded: Array(stored[40...]), isAtNewest: false)

        #expect(window.map(\.id) == stored.map(\.id))
    }

    @Test func `a refresh that no longer overlaps the window starts over at the newest messages`() {
        let stored = messages(400)
        let loaded = Array(stored[..<60])

        let window = MessageWindow.refreshed(loaded: loaded, reloaded: Array(stored[100...]), isAtNewest: false)

        #expect(window.map(\.id) == stored.suffix(MessageWindow.initialCount).map(\.id))
    }

    @Test func `at the newest message a refresh cuts the window to its resting count`() {
        let stored = messages(MessageWindow.restingCount + 200)

        let window = MessageWindow.refreshed(loaded: stored, reloaded: Array(stored.suffix(MessageWindow.refreshDepth)), isAtNewest: true)

        #expect(window.map(\.id) == stored.suffix(MessageWindow.restingCount).map(\.id))
    }

    @Test func `scrolled up a refresh keeps every loaded message`() {
        let stored = messages(MessageWindow.restingCount + 500)

        let window = MessageWindow.refreshed(loaded: stored, reloaded: Array(stored.suffix(MessageWindow.refreshDepth)), isAtNewest: false)

        #expect(window.map(\.id) == stored.map(\.id))
    }
}
