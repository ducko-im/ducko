import DuckoCore
import Foundation

/// What a scroller needs from the list that shows its rows.
@MainActor
protocol TranscriptScrollerList: AnyObject {
    /// Whether scrolling has come to rest: no gesture or its momentum is in progress and nothing has scrolled for a
    /// moment.
    var isAtRest: Bool { get }
    /// Takes the scroller's pending request, if it has one, and moves there.
    func takePendingRequest()
    /// Puts the view at `position` at once and reports where it ended up.
    func settle(at position: TranscriptPosition)
}

/// The one owner of a transcript's scroll position. It outlives the list that shows the rows, so a tab keeps its
/// place while another tab's rows are in the list.
@MainActor
final class TranscriptScroller {
    enum Request: Equatable {
        case newest
        case reveal(UUID)
    }

    /// Whether the view is at the newest message. While a list is attached it only changes when that list reports a
    /// position, so it says where the view is and never where it is heading.
    private(set) var isAtNewest = true {
        didSet {
            if isAtNewest != oldValue {
                onIsAtNewestChange?()
            }
        }
    }

    /// Called when the view has arrived at the newest message or left it. A list reports from inside a view update,
    /// so what runs here must put off anything that publishes.
    var onIsAtNewestChange: (() -> Void)?

    private(set) var position = TranscriptPosition.newest
    var heights = TranscriptHeights()
    private var pendingRequest: Request?
    private weak var list: (any TranscriptScrollerList)?
    /// A change waiting for scrolling to come to rest. Run once, by whichever of rest, the list detaching, or a
    /// reset comes first. A change handed over while one is waiting replaces it without running it.
    private var changeAwaitingRest: (() -> Void)?

    func scrollToNewest() {
        guard let list else {
            position = .newest
            isAtNewest = true
            return
        }
        pendingRequest = .newest
        list.takePendingRequest()
    }

    func reveal(_ id: UUID) {
        pendingRequest = .reveal(id)
        list?.takePendingRequest()
    }

    /// Runs `change` at once when the list is at rest or there is none, otherwise once it has come to rest. Changing
    /// the rows above what is being read while the view is moving would be seen as a jump.
    func performWhenAtRest(_ change: @escaping () -> Void) {
        if list?.isAtRest ?? true {
            change()
        } else {
            changeAwaitingRest = change
        }
    }

    /// Puts the view at `position`, drops a request still to be taken, and runs a change still waiting for rest.
    func reset(to position: TranscriptPosition) {
        pendingRequest = nil
        runChangeAwaitingRest()
        guard let list else {
            self.position = position
            isAtNewest = position == .newest
            return
        }
        list.settle(at: position)
    }

    // MARK: - For the list

    func attach(_ list: any TranscriptScrollerList) {
        self.list = list
    }

    /// An unselected tab must not keep a change parked behind a scroll nobody will see end.
    func detach(_ list: any TranscriptScrollerList) {
        guard self.list === list else { return }
        self.list = nil
        runChangeAwaitingRest()
    }

    func takeRequest() -> Request? {
        defer { pendingRequest = nil }
        return pendingRequest
    }

    func report(_ position: TranscriptPosition, isAtNewest: Bool) {
        self.position = position
        self.isAtNewest = isAtNewest
    }

    func listCameToRest() {
        runChangeAwaitingRest()
    }

    private func runChangeAwaitingRest() {
        guard let change = changeAwaitingRest else { return }
        changeAwaitingRest = nil
        change()
    }
}
