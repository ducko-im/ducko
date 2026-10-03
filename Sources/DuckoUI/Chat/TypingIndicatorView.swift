import DuckoCore
import SwiftUI

/// The row at the end of the timeline while the contact is typing, laid out like a message of theirs on its way.
struct TypingIndicatorRow: View {
    @Environment(ThemeEngine.self) private var theme
    let windowState: ChatWindowState

    var body: some View {
        HStack(alignment: .bottom) {
            if theme.current.showAvatars, theme.current.avatarPosition == .leading {
                // A room's typing notice does not say whose it is, so the avatar's place stays empty there.
                if windowState.isGroupchat {
                    Color.clear
                        .frame(width: theme.current.avatarSize, height: theme.current.avatarSize)
                } else {
                    SenderAvatarView(windowState: windowState, nickname: windowState.jidString)
                }
            }

            TypingIndicatorView()

            Spacer(minLength: 60)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(windowState.displayName) is typing")
        .accessibilityIdentifier("typing-indicator")
    }
}

/// Three dots in a bubble of the incoming color.
private struct TypingIndicatorView: View {
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(theme.textColor(isOutgoing: false, colorScheme: colorScheme).opacity(0.5))
                    .frame(width: 6, height: 6)
                    .offset(y: animating ? -4 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, theme.current.bubblePadding)
        .padding(.vertical, 10)
        .background(
            theme.bubbleColor(isOutgoing: false, colorScheme: colorScheme),
            in: .rect(cornerRadius: theme.current.bubbleCornerRadius)
        )
        .onAppear { animating = !reduceMotion }
    }
}
