import Testing
@testable import DuckoUI

struct ConversationActivitySlotTests {
    @Test(arguments: [
        (0, false, ""),
        (0, true, "Typing"),
        (1, false, "1 unread message"),
        (12, false, "12 unread messages"),
        (2, true, "2 unread messages")
    ])
    func `accessibility description names unread messages before typing`(unreadCount: Int, isTyping: Bool, expected: String) {
        let slot = ConversationActivitySlot(unreadCount: unreadCount, isTyping: isTyping, resting: .presence(.offline))
        #expect(slot.accessibilityDescription == expected)
    }
}
