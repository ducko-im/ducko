import DuckoCore
import SwiftUI

/// What a file going directly between devices is doing. Its row says so itself, since no server holds the file to speak for it.
enum DirectTransferStatus: Equatable {
    /// Waiting for the contact, as the chat names them, to accept.
    case waiting(recipient: String)
    /// `rate` is `nil` until the transfer has moved bytes long enough to tell.
    case sending(progress: Double, rate: TransferRate?)
    /// `progress` is `nil` until the first bytes arrive, and `rate` until they have arrived long enough to tell.
    case receiving(progress: Double?, rate: TransferRate?)
    case failed(String)
    case sent

    /// A reason for failing may run over several lines. Every other state takes one line, however long the name in
    /// it, so a row keeps its height from one state to the next.
    var lineLimit: Int? {
        if case .failed = self { nil } else { 1 }
    }

    /// The state as the status line shows it, which is also what VoiceOver reads as its label.
    var text: String {
        switch self {
        case let .waiting(recipient): "Waiting for \(recipient) to accept…"
        case .sending: "Sending directly…"
        case .receiving: "Receiving…"
        case let .failed(reason): reason
        case .sent: "Sent directly"
        }
    }

    /// How far the transfer is, and its rate and time left once known. Empty for a state that moves no bytes.
    var accessibilityValue: String {
        switch self {
        case let .sending(progress, rate): Self.progressText(progress, rate: rate)
        case let .receiving(progress, rate): progress.map { Self.progressText($0, rate: rate) } ?? ""
        case .waiting, .failed, .sent: ""
        }
    }

    private static func progressText(_ progress: Double, rate: TransferRate?) -> String {
        let percent = progress.formatted(.percent.precision(.fractionLength(0)))
        guard let rate else { return percent }
        return "\(percent), \(rate.displayText)"
    }

    /// What the row of a file being received says.
    static func receiving(_ transfer: FileTransferService.ActiveTransfer) -> DirectTransferStatus {
        if case let .transferring(progress) = transfer.state { return .receiving(progress: progress, rate: transfer.rate) }
        return .receiving(progress: nil, rate: nil)
    }

    /// `nil` for anything but a file this account sent directly, and for one whose transfer was cut off by a shutdown
    /// with no requested disconnect, of which nothing is known. A requested disconnect, quitting included, stores that
    /// the transfer stopped when you went offline. `recipientName` is the chat's name.
    static func resolve(
        for message: ChatMessage, transfer: FileTransferService.ActiveTransfer?, recipientName: String
    ) -> DirectTransferStatus? {
        guard message.isOutgoing, message.attachments.contains(where: { $0.localFileURL != nil }) else { return nil }
        // The stored outcome comes first, so a row reads the same while the app runs as after a relaunch.
        if let errorText = message.errorText { return .failed(errorText) }
        if message.isDelivered { return .sent }
        switch transfer?.state {
        case .negotiating, .awaitingAcceptance: return .waiting(recipient: recipientName)
        case .connectingTransport: return .sending(progress: 0, rate: nil)
        case let .transferring(progress): return .sending(progress: progress, rate: transfer?.rate)
        case let .failed(reason): return .failed(reason)
        case .completedTransfer: return .sent
        case .requestingSlot, .uploading, .completed, .received, nil: return nil
        }
    }
}

struct DirectTransferStatusView: View {
    let status: DirectTransferStatus?
    /// Stops the transfer. Without it, as in the History window, the row offers no way to.
    var stopTransfer: (() -> Void)?

    /// Fits the tallest state that takes one line, the one with a progress bar, so the row keeps its height as the
    /// transfer moves from one state to the next.
    private static let lineHeight: CGFloat = 20

    /// What the stop button says, or `nil` when the row shows none: without a way to stop the transfer, or once it has
    /// ended.
    var stopLabel: String? {
        guard stopTransfer != nil else { return nil }
        switch status {
        case .waiting, .sending: return "Stop sending"
        case .receiving: return "Stop receiving"
        case .failed, .sent, nil: return nil
        }
    }

    var body: some View {
        if let status {
            HStack(spacing: 6) {
                statusLine(status)
                if let stopTransfer, let stopLabel {
                    Button(stopLabel, systemImage: "xmark.circle.fill", action: stopTransfer)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(stopLabel)
                        .accessibilityIdentifier("stop-direct-transfer-button")
                }
            }
            .frame(minHeight: Self.lineHeight)
        }
    }

    /// The text and progress, read as one element whose label and value come from the status, so reading it never
    /// waits on the row's own update. The stop button stays apart from it, so it can be pressed.
    private func statusLine(_ status: DirectTransferStatus) -> some View {
        Group {
            switch status {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(status.text)
                        .singleLine()
                }
            case let .sending(progress, rate):
                HStack(spacing: 6) {
                    Text(status.text)
                    ProgressBar(fraction: progress)
                        .frame(width: 80)
                    rateText(rate)
                }
            case let .receiving(progress, rate):
                HStack(spacing: 6) {
                    if let progress {
                        ProgressBar(fraction: progress)
                            .frame(width: 80)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(status.text)
                    rateText(rate)
                }
            case let .failed(reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .sent:
                Text(status.text)
            }
        }
        .font(.caption2)
        .lineLimit(status.lineLimit)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.text)
        .accessibilityValue(status.accessibilityValue)
        .accessibilityIdentifier("direct-transfer-status")
    }

    @ViewBuilder
    private func rateText(_ rate: TransferRate?) -> some View {
        if let rate {
            Text(rate.displayText)
                .monospacedDigit()
                .singleLine()
        }
    }
}
