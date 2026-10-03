import AppKit
import Testing
@testable import DuckoApp

@MainActor
struct KeyboardFocusTests {
    private struct Fixture {
        let window: NSWindow
        let field: NSTextField
        let other: NSTextField
    }

    /// A window with two text fields, the first of which is being typed in with the cursor after "he".
    private static func makeFixture() throws -> Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let field = NSTextField(string: "hello")
        let other = NSTextField(string: "")
        field.frame = NSRect(x: 10, y: 60, width: 200, height: 24)
        other.frame = NSRect(x: 10, y: 20, width: 200, height: 24)
        window.contentView?.addSubview(field)
        window.contentView?.addSubview(other)
        try #require(window.makeFirstResponder(field))
        try #require(field.currentEditor() != nil)
        field.currentEditor()?.selectedRange = NSRange(location: 2, length: 0)
        return Fixture(window: window, field: field, other: other)
    }

    @Test func `the field being typed in gets the keyboard and its cursor back`() throws {
        let fixture = try Self.makeFixture()
        let focus = KeyboardFocus(in: fixture.window)
        // What losing the keyboard to another window does: the field's editing ends.
        try #require(fixture.window.makeFirstResponder(nil))
        try #require(fixture.field.currentEditor() == nil)

        focus.restore(in: fixture.window)

        #expect(fixture.field.currentEditor()?.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test(arguments: [true, false])
    func `a field that has left the window or been switched off since is passed over`(removed: Bool) throws {
        let fixture = try Self.makeFixture()
        let focus = KeyboardFocus(in: fixture.window)
        try #require(fixture.window.makeFirstResponder(fixture.other))
        if removed {
            fixture.field.removeFromSuperview()
        } else {
            fixture.field.isEnabled = false
        }

        focus.restore(in: fixture.window)

        // The field typed in since keeps the keyboard.
        #expect(fixture.other.currentEditor() != nil)
    }

    @Test func `a field still being typed in is left alone`() throws {
        let fixture = try Self.makeFixture()
        let focus = KeyboardFocus(in: fixture.window)
        fixture.field.currentEditor()?.selectedRange = NSRange(location: 4, length: 0)

        focus.restore(in: fixture.window)

        #expect(fixture.field.currentEditor()?.selectedRange == NSRange(location: 4, length: 0))
    }
}
