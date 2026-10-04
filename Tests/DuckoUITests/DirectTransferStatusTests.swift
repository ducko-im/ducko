import DuckoCore
import Foundation
import Testing
@testable import DuckoUI

struct DirectTransferStatusTests {
    private static let fileURL = URL(fileURLWithPath: "/tmp/holiday.png")

    private static func makeMessage(
        isOutgoing: Bool = true, sentDirectly: Bool = true, isDelivered: Bool = false, errorText: String? = nil
    ) -> ChatMessage {
        let attachment = sentDirectly
            ? Attachment.locallySaved(id: UUID(), fileURL: fileURL)
            : Attachment(id: UUID(), url: "https://upload.example.com/holiday.png")
        return ChatMessage(
            id: UUID(), conversationID: UUID(), fromJID: "bob@example.com", body: "",
            timestamp: Date(), isOutgoing: isOutgoing, isDelivered: isDelivered, isEdited: false,
            type: "chat", errorText: errorText, attachments: [attachment]
        )
    }

    private static func transfer(
        _ state: FileTransferService.TransferState, direction: FileTransferService.TransferDirection = .outgoing
    ) -> FileTransferService.ActiveTransfer {
        .init(id: UUID(), accountID: UUID(), fileName: "holiday.png", fileSize: 1, state: state, method: .jingle, direction: direction)
    }

    @Test(arguments: [
        (FileTransferService.TransferState.negotiating, DirectTransferStatus.waiting(recipient: "Bob")),
        (.connectingTransport, .sending(progress: 0)),
        (.transferring(progress: 0.4), .sending(progress: 0.4)),
        (.failed("The contact declined the transfer"), .failed("The contact declined the transfer")),
        (.completedTransfer, .sent)
    ])
    func `a running transfer speaks for its row`(state: FileTransferService.TransferState, expected: DirectTransferStatus) {
        let status = DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: Self.transfer(state), recipientName: "Bob")

        #expect(status == expected)
    }

    @Test func `the stored outcome speaks for the row, with or without its transfer`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isDelivered: true), transfer: nil, recipientName: "Bob") == .sent)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: nil, recipientName: "Bob") == .failed("Declined"))
        // The transfer's own wording gives way to what was stored, so the row reads the same after a relaunch.
        let failed = Self.transfer(.failed("File transfer failed: Declined"))
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: failed, recipientName: "Bob") == .failed("Declined"))
        // Cut off by the app quitting: nothing is known, so nothing is claimed.
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: nil, recipientName: "Bob") == nil)
    }

    @Test func `only a file this account sent directly has a status`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(sentDirectly: false, isDelivered: true), transfer: nil, recipientName: "Bob") == nil)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isOutgoing: false, isDelivered: true), transfer: nil, recipientName: "Bob") == nil)
    }

    @Test(arguments: [
        (FileTransferService.TransferState.connectingTransport, DirectTransferStatus.receiving(progress: nil)),
        (.transferring(progress: 0.4), .receiving(progress: 0.4))
    ] as [(FileTransferService.TransferState, DirectTransferStatus)])
    func `a file on its way in reports its progress on the row standing in for it`(
        state: FileTransferService.TransferState, expected: DirectTransferStatus
    ) {
        #expect(DirectTransferStatus.receiving(Self.transfer(state, direction: .incoming)) == expected)
    }
}
