import DuckoCore

/// Which of a chat's stored messages its window holds. The window is always a run of the store's messages in the
/// store's own order. Both functions go by position in a fetch result, never by timestamp, so messages that share a
/// second with a page boundary are neither skipped nor shown twice.
enum MessageWindow {
    /// How many messages a chat opens on.
    static let initialCount = 50
    /// How many older messages one step back adds.
    static let pageSize = 50
    /// How many of the newest messages a refresh reads again at most.
    static let refreshDepth = 250
    /// How many messages the window keeps while the reader is at the newest one.
    static let restingCount = 100
    /// How often in a row the server is asked for older entries that then give no page, before history counts as
    /// ended.
    static let serverRounds = 10

    /// The messages just before the window in `fetched`, which is in the store's order, oldest first: the newest page
    /// for an empty window. Nil when `fetched` does not hold the window's oldest message, so there is no telling
    /// where the window starts in it.
    static func olderPage(before loaded: [ChatMessage], in fetched: [ChatMessage]) -> [ChatMessage]? {
        guard let oldest = loaded.first else { return Array(fetched.suffix(pageSize)) }
        guard let index = fetched.firstIndex(where: { $0.id == oldest.id }) else { return nil }
        return Array(fetched[..<index].suffix(pageSize))
    }

    /// The window after the store's newest messages were read again as `reloaded`. What was loaded before them stays,
    /// as long as the two still overlap. Only at the newest message is the result cut back: scrolled up, dropping rows
    /// would take away what is being read.
    static func refreshed(loaded: [ChatMessage], reloaded: [ChatMessage], isAtNewest: Bool) -> [ChatMessage] {
        let window: [ChatMessage] = if let oldest = loaded.first, let index = reloaded.firstIndex(where: { $0.id == oldest.id }) {
            Array(reloaded[index...])
        } else if let first = reloaded.first, let index = loaded.firstIndex(where: { $0.id == first.id }) {
            loaded[..<index] + reloaded
        } else {
            Array(reloaded.suffix(initialCount))
        }
        return isAtNewest ? Array(window.suffix(restingCount)) : window
    }
}
