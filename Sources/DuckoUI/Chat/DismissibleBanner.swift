import SwiftUI

/// Orange warning banner with a message, an optional trailing control, and a dismiss button.
struct DismissibleBanner<Accessory: View>: View {
    let message: String
    let symbol: String
    let alignment: VerticalAlignment
    let dismissalLabel: String
    let dismissalShortcut: KeyboardShortcut?
    let onDismiss: () -> Void
    let accessory: Accessory

    init(
        message: String,
        symbol: String = "exclamationmark.triangle.fill",
        alignment: VerticalAlignment = .top,
        dismissalLabel: String = "Dismiss error",
        dismissalShortcut: KeyboardShortcut? = nil,
        onDismiss: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.message = message
        self.symbol = symbol
        self.alignment = alignment
        self.dismissalLabel = dismissalLabel
        self.dismissalShortcut = dismissalShortcut
        self.onDismiss = onDismiss
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            accessory
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(dismissalLabel)
            .keyboardShortcut(dismissalShortcut)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

extension DismissibleBanner where Accessory == EmptyView {
    init(
        message: String,
        symbol: String = "exclamationmark.triangle.fill",
        dismissalLabel: String = "Dismiss error",
        dismissalShortcut: KeyboardShortcut? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.init(
            message: message, symbol: symbol, dismissalLabel: dismissalLabel, dismissalShortcut: dismissalShortcut,
            onDismiss: onDismiss, accessory: { EmptyView() }
        )
    }
}
