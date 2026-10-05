import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct ContactCaptionTests {
    @Test
    func `status wins when a status message is present`() {
        let caption = ContactCaption.resolve(
            statusMessage: "Lunch", presence: .available,
            isCompact: false, isPendingSubscription: true, lastSeen: Date()
        )
        #expect(caption == .status("Lunch"))
        #expect(caption.hasSecondLine)
    }

    @Test
    func `status falls back to the presence display name when no message`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: .available,
            isCompact: false, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .status(PresenceService.PresenceStatus.available.displayName))
    }

    @Test
    func `compact rows show no caption, whatever applies`() {
        let caption = ContactCaption.resolve(
            statusMessage: "Lunch", presence: .available,
            isCompact: true, isPendingSubscription: true, lastSeen: Date()
        )
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }

    @Test
    func `pending shows when there is no status and no presence`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: nil,
            isCompact: false, isPendingSubscription: true, lastSeen: Date()
        )
        #expect(caption == .pendingApproval)
    }

    @Test
    func `last-seen shows when there is no presence and a timestamp`() {
        let lastSeen = Date(timeIntervalSince1970: 1_000_000)
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: nil,
            isCompact: false, isPendingSubscription: false, lastSeen: lastSeen
        )
        #expect(caption == .lastSeen(lastSeen))
    }

    @Test
    func `an empty status message still produces a status caption`() {
        // Documents current behavior: the status branch unwraps with `let`, not an
        // emptiness check, so an empty status string is treated as present.
        let caption = ContactCaption.resolve(
            statusMessage: "", presence: .available,
            isCompact: false, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .status(""))
        #expect(caption.hasSecondLine)
    }

    @Test
    func `no caption when nothing applies`() {
        let caption = ContactCaption.resolve(
            statusMessage: nil, presence: nil,
            isCompact: false, isPendingSubscription: false, lastSeen: nil
        )
        #expect(caption == .none)
        #expect(!caption.hasSecondLine)
    }
}
