import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

@MainActor
struct TranscriptScrollerTests {
    private let reading = TranscriptPosition.reading(id: UUID(), offset: 40)

    @Test func `with a list attached the position changes only when the list reports one`() {
        let scroller = TranscriptScroller()
        let list = StandInTranscriptList(attachedTo: scroller)
        list.arrive(at: reading)
        #expect(!scroller.isAtNewest)

        scroller.scrollToNewest()
        #expect(list.takenRequests == [.newest])
        #expect(!scroller.isAtNewest)

        scroller.reset(to: .newest)
        #expect(list.settledPositions == [.newest])
        #expect(!scroller.isAtNewest)
        #expect(scroller.position == reading)

        list.arrive(at: .newest)
        #expect(scroller.isAtNewest)
    }

    @Test func `with no list attached a scroll to the newest message and a reset take effect at once`() {
        let scroller = TranscriptScroller()
        let list = StandInTranscriptList(attachedTo: scroller)
        list.arrive(at: reading)
        scroller.detach(list)

        scroller.scrollToNewest()
        #expect(scroller.isAtNewest)
        #expect(scroller.position == .newest)

        scroller.reset(to: reading)
        #expect(!scroller.isAtNewest)
        #expect(scroller.position == reading)
    }

    @Test func `a change runs at once at rest or with no list, and otherwise exactly once on rest`() {
        var runs = 0
        let unattached = TranscriptScroller()
        unattached.performWhenAtRest { runs += 1 }
        #expect(runs == 1)

        let scroller = TranscriptScroller()
        let list = StandInTranscriptList(attachedTo: scroller)
        scroller.performWhenAtRest { runs += 1 }
        #expect(runs == 2)

        list.isAtRest = false
        scroller.performWhenAtRest { runs += 1 }
        #expect(runs == 2)
        list.comeToRest()
        #expect(runs == 3)
        list.comeToRest()
        #expect(runs == 3)
    }

    @Test func `a waiting change runs when the list detaches`() {
        var runs = 0
        let scroller = TranscriptScroller()
        let list = StandInTranscriptList(attachedTo: scroller)
        list.isAtRest = false
        scroller.performWhenAtRest { runs += 1 }

        scroller.detach(list)

        #expect(runs == 1)
    }

    @Test func `a reveal that waits for its row stays pending until the list holds it, and a reset drops it`() {
        let scroller = TranscriptScroller()
        let id = UUID()
        scroller.revealWhenShown(id)

        #expect(scroller.takeRequest(holdsRow: { _ in false }) == nil)
        #expect(scroller.takeRequest(holdsRow: { $0 == id }) == .revealWhenShown(id))
        #expect(scroller.takeRequest() == nil)

        scroller.revealWhenShown(id)
        scroller.reset(to: .oldest)
        #expect(scroller.takeRequest() == nil)
    }

    @Test func `a reset drops a pending request and runs a waiting change`() {
        var runs = 0
        let scroller = TranscriptScroller()
        // No list has taken the request yet.
        scroller.reveal(UUID())
        let list = StandInTranscriptList(attachedTo: scroller)
        list.isAtRest = false
        scroller.performWhenAtRest { runs += 1 }

        scroller.reset(to: .newest)

        #expect(runs == 1)
        #expect(scroller.takeRequest() == nil)
        list.comeToRest()
        #expect(runs == 1)
    }
}
