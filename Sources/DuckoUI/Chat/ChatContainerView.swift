import DuckoCore
import SwiftUI

public struct ChatContainerView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ChatContainerState.self) private var container
    @Environment(\.appearsActive) private var appearsActive

    public init() {}

    private var observedLastMessageDate: Date? {
        environment.chatService.openConversations
            .first { $0.id == container.selectedState?.conversation?.id }?
            .lastMessageDate
    }

    private var observedMessagesRevision: Int? {
        guard let id = container.selectedState?.conversation?.id else { return nil }
        return environment.chatService.messagesRevisions[id]
    }

    /// Membership snapshot of the service's live conversations. A `Set` so a
    /// rebuild that reorders `openConversations` doesn't fire the prune; only an
    /// actual add/remove does.
    private var observedConversationIDs: Set<UUID> {
        Set(environment.chatService.openConversations.map(\.id))
    }

    public var body: some View {
        @Bindable var container = container

        VStack(spacing: 0) {
            if let state = container.selectedState {
                ChatView(windowState: state)
            } else {
                emptyState
            }

            Divider()

            ChatTabBarView(container: container)
        }
        .frame(minWidth: 380, minHeight: 320)
        .background { secondaryTabShortcuts }
        .navigationTitle(container.selectedState?.displayName ?? "Chat")
        .focusedSceneValue(\.chatWindowState, container.selectedState)
        .onChange(of: observedLastMessageDate) {
            Task { await container.selectedState?.refreshMessages() }
        }
        .onChange(of: observedMessagesRevision) {
            Task { await container.selectedState?.refreshMessages() }
        }
        .onChange(of: observedConversationIDs) {
            container.pruneClosedConversations()
        }
        .onChange(of: appearsActive, initial: true) {
            container.isWindowFocused = appearsActive
        }
        .onAppear {
            container.isWindowOpen = true
        }
        .onDisappear {
            container.isWindowFocused = false
            container.isWindowOpen = false
        }
        .sheet(isPresented: $container.isShowingNewChat) {
            NewChatSheet { jidString, accountID in
                container.open(jidString, accountID: accountID)
            }
        }
    }

    /// ⌘⇧] / ⌘⇧[ as secondary bindings for Select Next/Previous Tab. A menu item carries only one shortcut, so these
    /// live on invisible buttons. The window matches them as key equivalents before the message field sees the
    /// keystroke.
    private var secondaryTabShortcuts: some View {
        ZStack {
            Button("Select Next Tab") { container.selectNextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Select Previous Tab") { container.selectPreviousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .disabled(!container.canCycleTabs)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No conversation open")
                .foregroundStyle(.secondary)
            Button("New Chat") {
                container.newChat()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat-empty-state")
    }
}
