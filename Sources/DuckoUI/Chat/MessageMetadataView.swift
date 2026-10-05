import DuckoCore
import SwiftUI

struct MessageMetadataView: View {
    let message: ChatMessage
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(message.timestamp, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)

            if message.isUndecryptable {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("undecryptable-indicator")
            } else if message.isEncrypted {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("encrypted-indicator")
            }

            if message.isOutgoing, message.isDelivered {
                deliveryMark
            }

            if message.isRetracted {
                Text(retractedLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(retractedTooltip)
            } else if message.isEdited {
                Text(editedLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(editedTooltip)
            }

            if message.errorText != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isVisible)
    }

    /// One check once the message reached the contact, two once they read it.
    private var deliveryMark: some View {
        let label = message.isDisplayed ? "Read" : "Delivered"
        return HStack(spacing: -4) {
            Image(systemName: "checkmark")
            if message.isDisplayed {
                Image(systemName: "checkmark")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier(message.isDisplayed ? "read-indicator" : "delivered-indicator")
    }

    private var editedLabel: String {
        if let editedAt = message.editedAt {
            return "(edited \(editedAt.formatted(.relative(presentation: .named))))"
        }
        return "(edited)"
    }

    private var editedTooltip: String {
        message.editedAt?.formatted(date: .abbreviated, time: .standard) ?? ""
    }

    private var retractedLabel: String {
        if let retractedAt = message.retractedAt {
            return "(retracted \(retractedAt.formatted(.relative(presentation: .named))))"
        }
        return "(retracted)"
    }

    private var retractedTooltip: String {
        message.retractedAt?.formatted(date: .abbreviated, time: .standard) ?? ""
    }
}
