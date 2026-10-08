import SwiftUI

struct CodeBlockView: View {
    let code: String
    let tint: Color
    /// A search's text, whose occurrences in the code are highlighted.
    var highlight: String?
    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        Text(code, highlighting: highlight)
            .monospaced()
            // The copy button only appears on hover, so expose copying as a named action
            // for keyboard and VoiceOver users.
            .accessibilityAction(named: "Copy Code", copy)
            .accessibilityIdentifier("code-block")
            .padding(8)
            // Room for the copy button, so it never covers code.
            .padding(.trailing, 20)
            .background(tint, in: .rect(cornerRadius: 6))
            .overlay(alignment: .topTrailing) {
                // Shown by presence rather than by opacity: an invisible button still takes clicks.
                if isHovering {
                    Button(didCopy ? "Copied" : "Copy Code", systemImage: didCopy ? "checkmark" : "doc.on.doc", action: copy)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Copy Code")
                        .padding(8)
                        .accessibilityIdentifier("code-block-copy-button")
                }
            }
            .onHover { isHovering = $0 }
            .task(id: didCopy) {
                guard didCopy else { return }
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
    }

    private func copy() {
        copyToPasteboard(code)
        didCopy = true
    }
}
