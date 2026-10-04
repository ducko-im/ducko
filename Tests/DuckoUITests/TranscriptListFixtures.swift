import DuckoCore
import Foundation
@testable import DuckoUI

private let transcriptRowConversationID = UUID()

/// A transcript row for the list tests: a History message row, which needs no chat behind it. Two rows made with one
/// id and one body are equal.
@MainActor
func makeTranscriptRow(id: UUID = UUID(), body: String = "A line of text") -> TranscriptRow {
    let message = ChatMessage(
        id: id, conversationID: transcriptRowConversationID, fromJID: "bob@example.com", body: body, timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        isOutgoing: false, isDelivered: true, isEdited: false, type: "chat"
    )
    return TranscriptRow(id: id, kind: .message(TranscriptRow.Message(
        message: message, position: MessagePosition(isFirstInGroup: true, isLastInGroup: true), isGroupchat: false, startsDay: false,
        replyQuote: nil, linkPreview: nil, transferStatus: nil, actionSenderName: "", loadsIncomingImagesOnSight: false, isSearchResult: false
    )))
}

/// Stands in for the list: it is at rest when told so, and reports a position only when the test has it do so, as a
/// real list reports only where the view has arrived.
@MainActor
final class StandInTranscriptList: TranscriptScrollerList {
    private let scroller: TranscriptScroller
    var isAtRest = true
    private(set) var takenRequests: [TranscriptScroller.Request] = []
    private(set) var settledPositions: [TranscriptPosition] = []

    init(attachedTo scroller: TranscriptScroller) {
        self.scroller = scroller
        scroller.attach(self)
    }

    func takePendingRequest() {
        if let request = scroller.takeRequest() {
            takenRequests.append(request)
        }
    }

    func settle(at position: TranscriptPosition) {
        settledPositions.append(position)
    }

    func arrive(at position: TranscriptPosition) {
        scroller.report(position, isAtNewest: position == .newest)
    }

    func comeToRest() {
        isAtRest = true
        scroller.listCameToRest()
    }
}
