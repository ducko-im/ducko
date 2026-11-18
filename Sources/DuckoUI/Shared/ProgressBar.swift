import SwiftUI

/// How far something is, drawn rather than shown with an AppKit progress indicator, filling the width it is given. A
/// determinate indicator whose value changes posts an accessibility notification from inside the view's update while an
/// accessibility client watches the window. SwiftUI answering it from that same update loops on itself and hangs the
/// app, so no view uses that control for progress.
struct ProgressBar: View {
    let fraction: Double

    private var clamped: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.tint)
                    .frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: 5)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(clamped.formatted(.percent.precision(.fractionLength(0))))
    }
}
