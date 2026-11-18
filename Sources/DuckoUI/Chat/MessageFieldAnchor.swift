import AppKit
import SwiftUI

/// Finds the AppKit text field the message field is drawn with. SwiftUI hands out no reference to it, and its
/// accessibility identifier is not set on the text field itself.
@MainActor
final class MessageFieldReference {
    fileprivate weak var anchor: NSView?

    /// The editable text field over the anchor, looked for among the views next to the anchor and then further out.
    var field: NSTextField? {
        guard let anchor, anchor.window != nil else { return nil }
        let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
        var branch = anchor
        while let parent = branch.superview {
            for sibling in parent.subviews where sibling !== branch {
                if let field = Self.editableField(in: sibling, at: anchor.convert(center, to: sibling)) {
                    return field
                }
            }
            branch = parent
        }
        return nil
    }

    /// `point` is in `view`'s coordinates. Only views under it are searched.
    private static func editableField(in view: NSView, at point: NSPoint) -> NSTextField? {
        guard !view.isHidden, view.bounds.contains(point) else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview, at: view.convert(point, to: subview)) {
                return field
            }
        }
        return nil
    }
}

/// Sits behind the message field, sharing its frame, so `MessageFieldReference` can find the field.
struct MessageFieldAnchor: NSViewRepresentable {
    let reference: MessageFieldReference

    func makeNSView(context _: Context) -> MessageFieldAnchorView {
        MessageFieldAnchorView()
    }

    func updateNSView(_ view: MessageFieldAnchorView, context _: Context) {
        reference.anchor = view
    }
}

/// Leaves clicks to the field in front of it.
final class MessageFieldAnchorView: NSView {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
