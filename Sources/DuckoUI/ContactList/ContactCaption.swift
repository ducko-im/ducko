import DuckoCore
import Foundation

/// The optional caption line a `ContactRow` shows beneath the contact's name.
/// One source of truth for the per-branch precedence so the row view (which
/// renders the text and style) and the contact-list height memo (which only
/// needs `hasSecondLine`) derive it identically — keeping the measured row
/// height in lockstep with what actually renders.
enum ContactCaption: Equatable {
    case status(String)
    case pendingApproval
    case lastSeen(Date)
    case none

    var hasSecondLine: Bool {
        self != .none
    }

    /// Account-scoped convenience reading the live presence service, matching the
    /// per-contact presence-key choice `ContactRow` renders against.
    @MainActor
    static func resolve(for contact: Contact, isCompact: Bool, presenceService: PresenceService) -> ContactCaption {
        resolve(
            statusMessage: presenceService.statusMessage(for: contact.jid, accountID: contact.accountID),
            presence: presenceService.presence(for: contact.jid, accountID: contact.accountID),
            isCompact: isCompact,
            isPendingSubscription: contact.isPendingSubscription,
            lastSeen: contact.lastSeen
        )
    }

    static func resolve(
        statusMessage: String?,
        presence: PresenceService.PresenceStatus?,
        isCompact: Bool,
        isPendingSubscription: Bool,
        lastSeen: Date?
    ) -> ContactCaption {
        guard !isCompact else { return .none }
        if let text = statusMessage ?? presence?.displayName {
            return .status(text)
        }
        if isPendingSubscription {
            return .pendingApproval
        }
        if let lastSeen {
            return .lastSeen(lastSeen)
        }
        return .none
    }
}
