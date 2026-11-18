import AppKit
import Carbon.HIToolbox
import Testing
@testable import DuckoUI

struct ChatTypingPolicyTests {
    typealias Key = ChatTypingPolicy.Key

    private static func redirects(
        _ key: Key, window: ChatTypingPolicy.WindowState = ChatTypingPolicy.WindowState(), responderTakesText: Bool = false,
        spaceActivatesControls: Bool = false
    ) -> Bool {
        ChatTypingPolicy.redirectsToMessageField(
            key, in: window, responderTakesText: responderTakesText, spaceActivatesControls: spaceActivatesControls
        )
    }

    private static func key(_ keyCode: Int, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> Key {
        Key(keyCode: UInt16(keyCode), modifiers: modifiers, characters: characters)
    }

    @Test(arguments: [
        key(kVK_ANSI_A, "a"),
        key(kVK_ANSI_A, "A", modifiers: [.shift]),
        key(kVK_ANSI_Semicolon, "ö"),
        key(kVK_ANSI_L, "@", modifiers: [.option]),
        key(kVK_ANSI_Keypad1, "1", modifiers: [.numericPad]),
        key(kVK_Space, " "),
        key(kVK_ANSI_A, "a", modifiers: [.capsLock])
    ])
    func `a typed character goes to the message field`(key: Key) {
        #expect(Self.redirects(key))
    }

    /// A dead key types nothing until the next key: ´ and ^ on a German keyboard, ⌥E on a US one and ⌥N on both.
    @Test(arguments: [
        key(kVK_ANSI_Equal),
        key(kVK_ISO_Section),
        key(kVK_ANSI_E, modifiers: [.option]),
        key(kVK_ANSI_N, modifiers: [.option]),
        key(kVK_ANSI_U, modifiers: [.option, .shift])
    ])
    func `a dead key goes to the message field to compose there`(key: Key) {
        #expect(Self.redirects(key))
    }

    @Test(arguments: [
        key(kVK_LeftArrow, "\u{F702}"), key(kVK_RightArrow, "\u{F703}"), key(kVK_UpArrow, "\u{F700}"), key(kVK_DownArrow, "\u{F701}"),
        key(kVK_Home, "\u{F729}"), key(kVK_End, "\u{F72B}"), key(kVK_PageUp, "\u{F72C}"), key(kVK_PageDown, "\u{F72D}"),
        key(kVK_Delete, "\u{7F}"), key(kVK_ForwardDelete, "\u{F728}"), key(kVK_Tab, "\t"), key(kVK_Tab, "\u{19}", modifiers: [.shift]),
        key(kVK_Escape, "\u{1B}"), key(kVK_Return, "\r"), key(kVK_ANSI_KeypadEnter, "\u{3}"), key(kVK_Help, "\u{F746}"),
        key(kVK_F1, "\u{F704}"), key(kVK_F12, "\u{F70F}"), key(kVK_F20, "\u{F717}"),
        key(kVK_LeftArrow, "\u{F702}", modifiers: [.option, .shift])
    ])
    func `a key that moves, deletes, confirms or runs a function stays where it is`(key: Key) {
        #expect(!Self.redirects(key))
    }

    @Test(arguments: [
        key(kVK_ANSI_KeypadClear, "\u{F739}"),
        key(kVK_ANSI_A, "\u{1}")
    ])
    func `a key that gives a control character stays where it is`(key: Key) {
        #expect(!Self.redirects(key))
    }

    @Test(arguments: [[.command], [.control], [.command, .shift], [.control, .option]] as [NSEvent.ModifierFlags])
    func `a command key stays where it is`(modifiers: NSEvent.ModifierFlags) {
        #expect(!Self.redirects(Self.key(kVK_ANSI_C, "c", modifiers: modifiers)))
        #expect(!Self.redirects(Self.key(kVK_ANSI_E, modifiers: modifiers)))
    }

    @Test func `typing is left alone without the window, while it opens quietly, under a sheet, or in something that takes text`() {
        #expect(!Self.redirects(Self.key(kVK_ANSI_A, "a"), window: ChatTypingPolicy.WindowState(isKey: false)))
        #expect(!Self.redirects(Self.key(kVK_ANSI_A, "a"), window: ChatTypingPolicy.WindowState(isOpeningQuietly: true)))
        #expect(!Self.redirects(Self.key(kVK_ANSI_A, "a"), window: ChatTypingPolicy.WindowState(hasSheet: true)))
        #expect(!Self.redirects(Self.key(kVK_ANSI_A, "a"), responderTakesText: true))
        #expect(!Self.redirects(Self.key(kVK_ANSI_Equal), responderTakesText: true))
    }

    @Test(arguments: [
        key(kVK_Space, " "),
        key(kVK_Space, "\u{A0}", modifiers: [.option]),
        key(kVK_Space, " ", modifiers: [.shift])
    ])
    func `space stays with the focused control under Full Keyboard Access`(key: Key) {
        #expect(!Self.redirects(key, spaceActivatesControls: true))
    }

    @Test(arguments: [
        key(kVK_ANSI_A, "a"),
        key(kVK_ANSI_Equal)
    ])
    func `other keys still go to the message field under Full Keyboard Access`(key: Key) {
        #expect(Self.redirects(key, spaceActivatesControls: true))
    }

    @MainActor
    @Test func `only text that can be edited takes text`() {
        let editable = NSTextView()
        let readOnly = NSTextView()
        readOnly.isEditable = false

        #expect(ChatTypingPolicy.takesText(editable))
        #expect(!ChatTypingPolicy.takesText(readOnly))
        #expect(ChatTypingPolicy.takesText(NSTextField(string: "draft")))
        #expect(!ChatTypingPolicy.takesText(NSTextField(labelWithString: "label")))
        #expect(!ChatTypingPolicy.takesText(NSView()))
        #expect(!ChatTypingPolicy.takesText(nil))
    }
}
