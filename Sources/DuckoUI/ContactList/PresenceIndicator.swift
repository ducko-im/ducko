import DuckoCore
import SwiftUI

struct PresenceIndicator: View {
    static let size: CGFloat = 8

    let display: ContactPresenceDisplay

    init(display: ContactPresenceDisplay) {
        self.display = display
    }

    /// Convenience for a known own/local presence, which is never unknown or pending.
    init(status: PresenceService.PresenceStatus?) {
        self.display = ContactPresenceDisplay.resolve(presence: status)
    }

    var body: some View {
        switch display {
        case .pending:
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2]))
                .foregroundStyle(.orange)
                .frame(width: Self.size, height: Self.size)
        case .unknown:
            Circle()
                .stroke(lineWidth: 1.5)
                .foregroundStyle(.gray)
                .frame(width: Self.size, height: Self.size)
        case .available, .away, .dnd, .offline:
            Circle()
                .fill(color)
                .frame(width: Self.size, height: Self.size)
        }
    }

    private var color: Color {
        switch display {
        case .available: .green
        case .away: .yellow
        case .dnd: .red
        case .offline, .unknown, .pending: .gray
        }
    }
}
