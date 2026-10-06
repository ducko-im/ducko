import SwiftUI

extension Text {
    /// Text whose line breaks are replaced by spaces. A one-line label would otherwise end at the first break, with
    /// room left over and nothing that `singleLine()` counts as cut off.
    init(joiningLines string: String) {
        self.init(string.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    /// Limits the text to one line and shows it in full as a tooltip while it is too wide to fit, the way AppKit's
    /// expansion tooltips do for a text field.
    func singleLine() -> some View {
        SingleLineText(text: self)
    }
}

extension EnvironmentValues {
    /// Set where rows are laid out only to read their height. `singleLine()` then leaves out its fit check, which
    /// costs more than the rest of a row and cannot change the height.
    @Entry var measuresHeightOnly = false
}

private struct SingleLineText: View {
    @Environment(\.measuresHeightOnly) private var measuresHeightOnly
    let text: Text

    var body: some View {
        let line = text.lineLimit(1)
        if measuresHeightOnly {
            line
        } else {
            // `ViewThatFits` takes the first view whose ideal width fits, so the tooltip exists only while the line
            // is cut off. `help` also sets the accessibility hint, which would have VoiceOver read the text twice,
            // so the empty hint clears it.
            ViewThatFits(in: .horizontal) {
                line
                line.help(text).accessibilityHint(Text(verbatim: ""))
            }
        }
    }
}
