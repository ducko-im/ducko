import AppKit

/// What has the keyboard inside a window, so it can be handed back. A window that loses the keyboard to another one,
/// even for a moment, ends the editing of the text field the user was typing in, and getting the keyboard back does
/// not resume it.
@MainActor
struct KeyboardFocus {
    private let responder: NSResponder?
    /// The selection in the text field being typed in, which starting to edit it again would otherwise replace with
    /// the whole text.
    private let selection: NSRange?

    init(in window: NSWindow) {
        // A text field is typed in through the window's shared editor, which goes back to the window when editing
        // ends. The field itself is what can be given the keyboard again.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSTextField {
            self.responder = field
            self.selection = editor.selectedRange()
        } else {
            self.responder = window.firstResponder
            self.selection = nil
        }
    }

    func restore(in window: NSWindow) {
        // One that has left the window or been switched off since is passed over: asked to give it the keyboard, the
        // window would take the keyboard from whatever has it now and keep it for itself.
        guard let responder, responder !== window, responder.acceptsFirstResponder,
              (responder as? NSView).map({ $0.window === window }) ?? true else { return }
        if let field = responder as? NSTextField {
            guard field.currentEditor() == nil, window.makeFirstResponder(field) else { return }
            if let selection {
                field.currentEditor()?.selectedRange = selection
            }
        } else if window.firstResponder !== responder {
            window.makeFirstResponder(responder)
        }
    }
}
