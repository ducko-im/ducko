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
        (FileTransferService.TransferState.negotiating, DirectTransferStatus.waiting),
        (.connectingTransport, .sending(progress: 0)),
        (.transferring(progress: 0.4), .sending(progress: 0.4)),
        (.failed("The peer declined the transfer"), .failed("The peer declined the transfer")),
        (.completedTransfer, .sent)
    ])
    func `a running transfer speaks for its row`(state: FileTransferService.TransferState, expected: DirectTransferStatus) {
        let status = DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: Self.transfer(state))

        #expect(status == expected)
    }

    @Test func `the stored outcome speaks for the row, with or without its transfer`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isDelivered: true), transfer: nil) == .sent)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: nil) == .failed("Declined"))
        // The transfer's own wording gives way to what was stored, so the row reads the same after a relaunch.
        let failed = Self.transfer(.failed("File transfer failed: Declined"))
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: failed) == .failed("Declined"))
        // Cut off by the app quitting: nothing is known, so nothing is claimed.
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: nil) == nil)
    }

    @Test func `only a file this account sent directly has a status`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(sentDirectly: false, isDelivered: true), transfer: nil) == nil)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isOutgoing: false, isDelivered: true), transfer: nil) == nil)
    }

    @Test(arguments: [
        (FileTransferService.TransferState.connectingTransport, DirectTransferStatus.receiving(progress: nil)),
        (.transferring(progress: 0.4), .receiving(progress: 0.4)),
        // Once saved, the file's own message takes over from the row that stood in for it.
        (.received(fileURL: fileURL), nil),
        (.failed("The transfer timed out"), nil)
    ] as [(FileTransferService.TransferState, DirectTransferStatus?)])
    func `a file on its way in reports its progress on the row standing in for it`(
        state: FileTransferService.TransferState, expected: DirectTransferStatus?
    ) {
        let standIn = Self.makeMessage(isOutgoing: false, sentDirectly: false)

        #expect(DirectTransferStatus.resolve(for: standIn, transfer: Self.transfer(state, direction: .incoming)) == expected)
    }
}
