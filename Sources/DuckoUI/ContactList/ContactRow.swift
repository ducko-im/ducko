import DuckoCore
import SwiftUI

struct ContactRow: View {
    @Environment(AppEnvironment.self) private var environment
    let contact: Contact
    let isCompact: Bool

    private var display: ContactPresenceDisplay {
        ContactPresenceDisplay.resolve(for: contact, accountID: contact.accountID, presenceService: environment.presenceService)
    }

    private var caption: ContactCaption {
        ContactCaption.resolve(for: contact, isCompact: isCompact, presenceService: environment.presenceService)
    }

    /// The disambiguation label shown when this contact's JID is on more than one account; nil otherwise.
    private var accountLabel: String? {
        AccountIndicator.label(
            for: contact.accountID, bareJID: contact.jid.description,
            accountService: environment.accountService, rosterService: environment.rosterService
        )
    }

    /// JID-only when unique; account-qualified when the JID is duplicated so the two same-JID rows
    /// are individually addressable by automation. Single-account users keep the plain `{jid}` id.
    private var accessibilityKey: String {
        AccountIndicator.qualified(contact.jid.description, accountID: contact.accountID, qualify: accountLabel != nil, accountService: environment.accountService)
    }

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(display: display)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(contact.displayName)
                        .fontWeight(.medium)
                        .singleLine()

                    if let accountLabel {
                        AccountLabelText(label: accountLabel)
                    }
                }

                switch caption {
                case let .status(statusText):
                    Text(joiningLines: statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .singleLine()
                case .pendingApproval:
                    Text("Pending approval")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .singleLine()
                case let .lastSeen(date):
                    Text("Last seen \(date, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .singleLine()
                case .none:
                    EmptyView()
                }
            }

            Spacer()

            if !isCompact {
                AvatarView(contact: contact)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("contact-row-\(accessibilityKey)")
    }
}
