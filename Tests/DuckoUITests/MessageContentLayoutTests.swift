import AppKit
import DuckoCore
import Foundation
import SwiftUI
import Testing
@testable import DuckoUI

@MainActor
struct MessageContentLayoutTests {
    @Test func `a reply takes the height its quote and text ask for, whatever height it is offered`() {
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "bob@example.com",
            body: String(repeating: "A reply long enough to wrap onto several lines. ", count: 4),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: true, isDelivered: true, isEdited: false, type: "chat"
        )
        let content = MessageContentView(
            message: message, isGroupchatIncoming: false, isMetadataVisible: true, actionSenderName: "",
            loadsIncomingImagesOnSight: false, transferStatus: nil,
            header: { ReplyQuoteView(senderName: "alice@example.com", bodyPreview: "Two lines\nof quoted text") },
            footer: { EmptyView() }
        )
        let controller = NSHostingController(rootView: content)

        let offeredLittle = controller.sizeThatFits(in: CGSize(width: 400, height: 60)).height
        let offeredMuch = controller.sizeThatFits(in: CGSize(width: 400, height: 2000)).height

        #expect(offeredLittle == offeredMuch)
    }

    /// A highlight only recolors text. A row that changed height with it would shift the rows below each time a search
    /// comes or goes.
    @Test func `a message is as tall with a search's text highlighted as without`() {
        let message = ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "bob@example.com",
            body: String(repeating: "A message long enough to wrap onto several lines. ", count: 4),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), isOutgoing: false, isDelivered: true, isEdited: false, type: "chat"
        )
        let height = { (highlight: String?) in
            let content = MessageContentView(
                message: message, isGroupchatIncoming: false, isMetadataVisible: true, actionSenderName: "",
                loadsIncomingImagesOnSight: false, transferStatus: nil, highlight: highlight
            )
            return NSHostingController(rootView: content).sizeThatFits(in: CGSize(width: 400, height: 2000)).height
        }

        #expect(height("wrap") == height(nil))
    }
}
