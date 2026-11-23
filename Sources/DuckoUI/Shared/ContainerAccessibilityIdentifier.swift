import SwiftUI

extension View {
    /// Gives a view holding other accessibility elements an identifier of its own while its children keep theirs.
    /// A bare `accessibilityIdentifier` on such a view can be passed down to its children instead, replacing the
    /// identifiers they carry, so automation that looks for a child by its own identifier finds nothing.
    func containerAccessibilityIdentifier(_ identifier: String) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
