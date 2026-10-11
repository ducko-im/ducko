import SwiftUI

/// A conversation's leading indicator on a chat tab and a contact-list row: an unread count, else a typing bubble while
/// the contact types, else the conversation's resting indicator. A count outranks the bubble, since a waiting message
/// says more than the next one being written.
///
/// The slot is one fixed square whatever it shows, so a count or a typing bubble coming and going never moves the label
/// beside it or resizes the row.
struct ConversationActivitySlot: View {
    static let size: CGFloat = 16
    /// How far the slot reaches past each side of the presence dot at its center.
    static let dotOverhang = (size - PresenceIndicator.size) / 2

    /// What the slot shows while nothing is unread or being typed.
    enum Resting {
        case presence(ContactPresenceDisplay)
        case symbol(String)
    }

    let unreadCount: Int
    let isTyping: Bool
    let resting: Resting

    /// What the slot says beyond presence, for VoiceOver and automation.
    var accessibilityDescription: String {
        if unreadCount > 0 {
            return unreadCount == 1 ? "1 unread message" : "\(unreadCount) unread messages"
        }
        return isTyping ? "Typing" : ""
    }

    var body: some View {
        indicator
            .frame(width: Self.size, height: Self.size)
            // The surface reads `accessibilityDescription` out as its value, so the badge and bubble stay out of its label.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var indicator: some View {
        if unreadCount > 0 {
            Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                .font(.caption2.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(.red))
        } else if isTyping {
            Image(systemName: "ellipsis.bubble.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            switch resting {
            case let .presence(display):
                PresenceIndicator(display: display)
            case let .symbol(name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
