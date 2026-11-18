import AppKit
import Carbon.HIToolbox

/// Whether a key typed in the chat window while nothing there takes text goes to the message field instead.
enum ChatTypingPolicy {
    /// A key pressed.
    struct Key {
        /// Which key it is on the keyboard, whatever the layout makes it type.
        var keyCode: UInt16
        /// The modifier keys held. With ⌘ or ⌃ the key is a command, such as ⌘C copying the selection.
        var modifiers: NSEvent.ModifierFlags = []
        /// What the key types. A dead key, such as ⌥E, or ´ on a German keyboard, types nothing until the next key.
        var characters = ""
    }

    /// What the chat window is doing when the key is typed.
    struct WindowState {
        /// Whether the window has the keyboard.
        var isKey = true
        /// Whether the window is opening without taking the keyboard from the window the user types in. It can have
        /// the keyboard for a moment while it opens, and a key typed then was meant for that other window.
        var isOpeningQuietly = false
        /// Whether a sheet is attached to the window.
        var hasSheet = false
    }

    /// Keys that move, delete, confirm, cancel or run a function rather than type.
    private static let keysThatTypeNothing: Set<Int> = [
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
        kVK_Delete, kVK_ForwardDelete, kVK_Tab, kVK_Escape, kVK_Return, kVK_ANSI_KeypadEnter, kVK_Help,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
    ]

    /// A key outside `keysThatTypeNothing` is taken to type, a dead key included, which is told apart by the key rather
    /// than by what it types, since it types nothing yet.
    /// - Parameters:
    ///   - window: What the chat window is doing. Only a window that has the keyboard, with no sheet and not opening
    ///     quietly, sends keys on.
    ///   - responderTakesText: Whether what has the keyboard is something the user types in. That keeps every key.
    ///   - spaceActivatesControls: Whether Full Keyboard Access is on. Space then presses the control that has the
    ///     keyboard, and stays with it.
    static func redirectsToMessageField(
        _ key: Key, in window: WindowState, responderTakesText: Bool, spaceActivatesControls: Bool
    ) -> Bool {
        guard window.isKey, !window.isOpeningQuietly, !window.hasSheet, !responderTakesText,
              key.modifiers.isDisjoint(with: [.command, .control]) else { return false }
        let keyCode = Int(key.keyCode)
        if spaceActivatesControls, keyCode == kVK_Space { return false }
        return !keysThatTypeNothing.contains(keyCode) && !isControl(key.characters)
    }

    /// Whether `responder` is something the user types in. Text that can only be read and selected is not. A text
    /// input of another kind is taken to be, since whether it can be typed in cannot be told.
    @MainActor
    static func takesText(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView { return textView.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return responder is NSTextInputClient
    }

    /// Whether `text` is what a key that types nothing gives: a control character, or a character from the range
    /// AppKit reserves for keys such as the arrows and the function keys. That covers such keys missing from
    /// `keysThatTypeNothing`, and a layout that makes a key give a control character.
    private static func isControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || (0xF700 ... 0xF8FF).contains(scalar.value)
        }
    }
}
