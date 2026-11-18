/// Where the chat window puts the keyboard when the user comes back to it, when another tab is picked, or when the find
/// bar closes.
enum ChatKeyboardPolicy {
    enum Action: Equatable {
        /// The keyboard stays where it is.
        case leave
        /// Something other than the message field that the user types in, such as the find bar's field, has the
        /// keyboard and keeps it. No field is due to take it any longer.
        case keepTextInput
        /// What had the keyboard when the window lost it gets it back, and the message field when nothing can.
        case restore
        case focus(Field)
    }

    /// What has the keyboard in the window.
    enum Holder {
        /// Nothing but the window itself.
        case window
        /// Something the user types in other than the message field.
        case otherTextInput
        /// Anything else, the message field included.
        case view
    }

    /// A field of the shown tab that takes the keyboard.
    enum Field: Equatable {
        case message
        /// The find bar's field.
        case search

        /// The find bar's field while the bar is open, and the message field otherwise.
        init(isSearching: Bool) {
            self = isSearching ? .search : .message
        }
    }

    /// - Parameters:
    ///   - isKey: Whether the chat window has the keyboard.
    ///   - hasSheet: Whether a sheet is attached to the window.
    ///   - isOpeningQuietly: Whether the window is still being put behind the window the user is in. It must not take
    ///     the keyboard from that window.
    ///   - holder: What has the keyboard in the window.
    ///   - dueField: The shown tab's field that is to take the keyboard, set when the window opened, another tab was
    ///     picked or the find bar closed since a field last got it. A restored window starts with its transcript
    ///     holding the keyboard, which a new tab's field takes from it.
    static func action(isKey: Bool, hasSheet: Bool, isOpeningQuietly: Bool, holder: Holder, dueField: Field?) -> Action {
        guard isKey, !hasSheet, !isOpeningQuietly else { return .leave }
        switch holder {
        case .otherTextInput:
            return .keepTextInput
        case .window:
            return dueField.map(Action.focus) ?? .restore
        case .view:
            return dueField.map(Action.focus) ?? .leave
        }
    }
}
