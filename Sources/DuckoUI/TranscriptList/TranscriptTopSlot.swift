import SwiftUI

/// The row above the oldest loaded message while there is history left to load. One height whatever it shows, so
/// nothing below it moves when a load starts or ends.
struct TranscriptTopSlot: View {
    let isLoading: Bool

    var body: some View {
        ZStack {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
    }
}
