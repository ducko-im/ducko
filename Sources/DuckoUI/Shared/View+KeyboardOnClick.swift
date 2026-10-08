import SwiftUI

extension View {
    /// Gives a list the keyboard on every click in it, a click on the row already selected included, so that the arrow
    /// keys move its selection afterwards. A `List(selection:)` does not take the keyboard on a click by itself.
    /// Selecting a row from code leaves the keyboard where it is.
    func takesKeyboardOnClick() -> some View {
        modifier(KeyboardOnClick())
    }
}

private struct KeyboardOnClick: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            // On the list, where selection keeps working. On a row it would take the clicks that select.
            .simultaneousGesture(TapGesture().onEnded { isFocused = true })
    }
}
