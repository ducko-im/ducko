import SwiftUI

/// A collapsible group header. The whole row toggles expansion (not just the
/// chevron), matching Adium, and is excluded from list selection by the caller.
struct GroupHeaderRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let name: String
    var online: Int = 0
    var total: Int = 0
    var showCount: Bool = true
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Rotate in lockstep with the rows sliding into/out of the
                    // header; the cell is re-hosted on toggle so this implicit
                    // animation drives the rotation.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
                    // Same 8-pt slot as the contact status dots so the chevron's
                    // center aligns with the dot column above/below it.
                    .frame(width: 8)

                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .singleLine()

                Spacer()

                if showCount {
                    Text("\(online) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
