import SwiftUI

/// The secondary account-disambiguation label rendered beside a contact/tab name when the same peer
/// JID is on more than one account. Shared so the contact row and chat tab chip style it identically.
struct AccountLabelText: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .singleLine()
            .layoutPriority(-1)
    }
}
