import DuckoCore
import SwiftUI

/// A note between messages, such as encryption having been switched on.
struct TimelineNoteView: View {
    let note: TimelineNote
    let contactName: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
            Text(note.text(contactName: contactName))
                .multilineTextAlignment(.center)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("timeline-note")
    }

    private var symbolName: String {
        switch note.kind {
        case .encryptionEnabledByContact: "lock.fill"
        }
    }
}
