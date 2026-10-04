import DuckoCore
import Foundation

struct MessagePosition: Equatable {
    let isFirstInGroup: Bool
    let isLastInGroup: Bool
}

/// A note between two messages ends the group before it and starts a new one after it.
func computeMessagePositions(
    _ items: [TimelineItem],
    groupingInterval: TimeInterval = 120
) -> [UUID: MessagePosition] {
    var positions: [UUID: MessagePosition] = [:]

    for (index, item) in items.enumerated() {
        guard case let .message(message) = item else { continue }
        let prevMessage = index > 0 ? items[index - 1].message : nil
        let nextMessage = index < items.count - 1 ? items[index + 1].message : nil

        let isFirstInGroup = !isSameGroup(message, as: prevMessage, interval: groupingInterval)
        let isLastInGroup = !isSameGroup(message, as: nextMessage, interval: groupingInterval)

        positions[message.id] = MessagePosition(isFirstInGroup: isFirstInGroup, isLastInGroup: isLastInGroup)
    }

    return positions
}

private extension TimelineItem {
    var message: ChatMessage? {
        if case let .message(message) = self { message } else { nil }
    }
}

private func isSameGroup(_ a: ChatMessage, as b: ChatMessage?, interval: TimeInterval) -> Bool {
    guard let b else { return false }
    guard a.isOutgoing == b.isOutgoing else { return false }
    guard a.fromJID == b.fromJID else { return false }
    return abs(a.timestamp.timeIntervalSince(b.timestamp)) <= interval
}
