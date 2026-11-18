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

    /// 2.1 MB/s with 15 seconds left.
    private static let rate = TransferRate(bytesPerSecond: 2_100_000, bytesTransferred: 10_000_000, totalBytes: 41_500_000)

    private static func transfer(
        _ state: FileTransferService.TransferState, direction: FileTransferService.TransferDirection = .outgoing, rate: TransferRate? = nil
    ) -> FileTransferService.ActiveTransfer {
        var transfer = FileTransferService.ActiveTransfer(
            id: UUID(), accountID: UUID(), fileName: "holiday.png", fileSize: 1, state: state, method: .jingle, direction: direction
        )
        transfer.rate = rate
        return transfer
    }

    @Test(arguments: [
        (FileTransferService.TransferState.negotiating, DirectTransferStatus.waiting(recipient: "Bob")),
        (.connectingTransport, .sending(progress: 0, rate: nil)),
        (.transferring(progress: 0.4), .sending(progress: 0.4, rate: nil)),
        (.failed("The contact declined the transfer"), .failed("The contact declined the transfer")),
        (.completedTransfer, .sent)
    ])
    func `a running transfer speaks for its row`(state: FileTransferService.TransferState, expected: DirectTransferStatus) {
        let status = DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: Self.transfer(state), recipientName: "Bob")

        #expect(status == expected)
    }

    @Test func `a file being sent carries how fast it moves`() {
        let transfer = Self.transfer(.transferring(progress: 0.4), rate: Self.rate)

        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: transfer, recipientName: "Bob") == .sending(progress: 0.4, rate: Self.rate))
    }

    @Test func `the stored outcome speaks for the row, with or without its transfer`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isDelivered: true), transfer: nil, recipientName: "Bob") == .sent)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: nil, recipientName: "Bob") == .failed("Declined"))
        // The transfer's own wording gives way to what was stored, so the row reads the same after a relaunch.
        let failed = Self.transfer(.failed("File transfer failed: Declined"))
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(errorText: "Declined"), transfer: failed, recipientName: "Bob") == .failed("Declined"))
        // Cut off by a shutdown nobody asked for: nothing is known, so nothing is claimed.
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(), transfer: nil, recipientName: "Bob") == nil)
    }

    @Test func `only a file this account sent directly has a status`() {
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(sentDirectly: false, isDelivered: true), transfer: nil, recipientName: "Bob") == nil)
        #expect(DirectTransferStatus.resolve(for: Self.makeMessage(isOutgoing: false, isDelivered: true), transfer: nil, recipientName: "Bob") == nil)
    }

    @Test(arguments: [
        (FileTransferService.TransferState.connectingTransport, DirectTransferStatus.receiving(progress: nil, rate: nil)),
        (.transferring(progress: 0.4), .receiving(progress: 0.4, rate: rate))
    ] as [(FileTransferService.TransferState, DirectTransferStatus)])
    func `a file on its way in reports its progress and rate on the row standing in for it`(
        state: FileTransferService.TransferState, expected: DirectTransferStatus
    ) {
        #expect(DirectTransferStatus.receiving(Self.transfer(state, direction: .incoming, rate: Self.rate)) == expected)
    }

    @MainActor
    @Test(arguments: [
        (DirectTransferStatus.waiting(recipient: "Bob"), "Stop sending"),
        (.sending(progress: 0, rate: nil), "Stop sending"),
        (.sending(progress: 0.4, rate: rate), "Stop sending"),
        (.receiving(progress: nil, rate: nil), "Stop receiving"),
        (.receiving(progress: 0.4, rate: rate), "Stop receiving"),
        (.failed("The contact declined the transfer"), nil),
        (.sent, nil)
    ] as [(DirectTransferStatus, String?)])
    func `a transfer under way can be stopped from its row`(status: DirectTransferStatus, expectedLabel: String?) {
        #expect(DirectTransferStatusView(status: status, stopTransfer: {}).stopLabel == expectedLabel)
    }

    /// The status line is one accessibility element whose label and value come from the status itself, so a reader
    /// hears the state and how far it is without the line's views being read.
    @Test func `the status line reads its state as the label and its progress and rate as the value`() throws {
        let rate = try #require(TransferRate(bytesPerSecond: 2_000_000, bytesTransferred: 4_000_000, totalBytes: 10_000_000))
        let sending = DirectTransferStatus.sending(progress: 0.4, rate: rate)
        #expect(sending.text == "Sending directly…")
        #expect(sending.accessibilityValue == "\(0.4.formatted(.percent.precision(.fractionLength(0)))), \(rate.displayText)")
        #expect(DirectTransferStatus.sending(progress: 0.4, rate: nil).accessibilityValue == 0.4.formatted(.percent.precision(.fractionLength(0))))
        #expect(DirectTransferStatus.receiving(progress: nil, rate: nil).accessibilityValue.isEmpty)
        #expect(DirectTransferStatus.receiving(progress: 0.5, rate: nil).text == "Receiving…")
        #expect(DirectTransferStatus.waiting(recipient: "Bob").text == "Waiting for Bob to accept…")
        #expect(DirectTransferStatus.failed("The transfer was canceled").text == "The transfer was canceled")
        #expect(DirectTransferStatus.sent.accessibilityValue.isEmpty)
        let percent = 0.5.formatted(.percent.precision(.fractionLength(0)))
        #expect(DirectTransferStatus.receiving(progress: 0.5, rate: rate).accessibilityValue == "\(percent), \(rate.displayText)")
        #expect(DirectTransferStatus.receiving(progress: 0.5, rate: nil).accessibilityValue == percent)
    }

    @MainActor
    @Test func `a row given no way to stop its transfer, as in the History window, shows no stop button`() {
        #expect(DirectTransferStatusView(status: .sending(progress: 0.4, rate: Self.rate)).stopLabel == nil)
    }
}
