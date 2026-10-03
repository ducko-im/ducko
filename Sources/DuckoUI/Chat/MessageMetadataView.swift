import DuckoCore
import SwiftUI

struct MessageMetadataView: View {
    @Environment(ThemeEngine.self) private var theme
    let message: ChatMessage
    let isVisible: Bool

    var body: some View {
        HStack(spacing: 4) {
            timestampText
                .font(theme.current.timestampFont.resolved)
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

    @ViewBuilder
    private var timestampText: some View {
        if theme.current.timestampStyle == .grouped {
            EmptyView()
        } else if let format = theme.current.timestampFormat {
            Text(formattedTimestamp(format))
        } else {
            Text(message.timestamp, style: .time)
        }
    }

    private static var formatters: [String: DateFormatter] = [:]

    private func formattedTimestamp(_ format: String) -> String {
        let formatter = Self.formatters[format] ?? {
            let f = DateFormatter()
            f.dateFormat = format
            Self.formatters[format] = f
            return f
        }()
        return formatter.string(from: message.timestamp)
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
