import AppKit
import DuckoCore
import DuckoData
import DuckoUI
import Logging
import SwiftData
import SwiftUI

private let log = Logger(label: "im.ducko.app.lifecycle")

@main
struct DuckoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment
    @State private var chatContainer: ChatContainerState
    @State private var transcriptScope = TranscriptScope()
    @State private var themeEngine = ThemeEngine()
    @State private var generalPreferences = GeneralPreferences()
    @State private var statusBarPreferences = StatusBarPreferences()
    @State private var updateManager = UpdateManager()
    @State private var notificationManager = NotificationManager()
    @FocusedValue(\.chatWindowState) private var focusedChatWindowState
    @FocusedValue(\.contactListWindowState) private var focusedContactListWindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isShowingAdiumImport = false

    init() {
        LoggingConfiguration.bootstrap()
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            let container = try ModelContainerFactory.makeContainer()
            let store = SwiftDataPersistenceStore(modelContainer: container)
            let omemoStore = SwiftDataOMEMOStore(modelContainer: container)
            let transcripts = FileTranscriptStore.makeDefault()
            let env = AppEnvironment(store: store, transcripts: transcripts, omemoStore: omemoStore, linkPreviewFetcher: LPLinkPreviewFetcher())
            self.environment = env
            let chatContainer = ChatContainerState(environment: env, defaults: PreferencesDefaults.store)
            self.chatContainer = chatContainer
            AppStateObserver(accountService: env.accountService)
            AppDelegate.environment = env
            AppDelegate.chatContainer = chatContainer
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }

    /// Built from the app-owned container + `openWindow` so every scene shares one
    /// open-chat behavior: create/select the tab, then surface the single chat window.
    private var openChatAction: OpenChatAction {
        OpenChatAction { jidString, accountID in
            chatContainer.open(jidString, accountID: accountID)
            openChatWindow()
        }
    }

    /// Brings the chat window up because the user asked for it. One that is just opening on its own stays in front
    /// from here on.
    private func openChatWindow() {
        QuietWindow.stopWatching()
        openWindow(id: "chat")
    }

    var body: some Scene {
        Window("Welcome", id: "welcome") {
            WelcomeView()
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 520, height: 620)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Contacts", id: "contacts") {
            ContentView()
                .environment(environment)
                .environment(themeEngine)
                .environment(chatContainer)
                .environment(transcriptScope)
                .environment(statusBarPreferences)
                .environment(\.openChat, openChatAction)
                .task {
                    notificationManager.requestAuthorization()
                    wireNotifications()
                }
                .onChange(of: totalUnread) { _, newValue in
                    notificationManager.updateDockBadge(totalUnread: newValue)
                }
                .sheet(isPresented: $isShowingAdiumImport) {
                    AdiumImportView()
                        .environment(environment)
                }
        }
        .defaultSize(width: 280, height: 320)
        .defaultPosition(.topLeading)
        .defaultLaunchBehavior(.presented)
        // The coordinator owns the frame; the `windowWillResize` gate vetoes
        // user drags on the auto-size axes. `.automatic` resolves to
        // `.contentMinSize` for a `Window`, so the matched `.frame(minWidth:
        // minHeight:)` must track the coordinator's lower bound — otherwise
        // SwiftUI snaps the window when the chrome grows.
        .windowResizability(.automatic)

        Window("Chat", id: "chat") {
            ChatContainerView()
                .environment(environment)
                .environment(themeEngine)
                .environment(chatContainer)
                .environment(transcriptScope)
                .environment(\.openChat, openChatAction)
        }
        .defaultSize(width: 500, height: 450)
        .windowResizability(.contentMinSize)

        WindowGroup("Contact Info", id: "contact-info", for: ContactInfoRef.self) { $ref in
            ContactInfoWindow(ref: $ref)
                .environment(environment)
                .environment(themeEngine)
        }
        .defaultSize(width: 400, height: 520)

        Window("Chat Transcripts", id: "transcripts") {
            TranscriptViewerWindow()
                .environment(environment)
                .environment(themeEngine)
                .environment(transcriptScope)
        }
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateManager.checkForUpdates()
                }
                .disabled(!updateManager.canCheckForUpdates)

                Button("Install Command Line Tools…") {
                    CLIInstaller.installCLITools()
                }
            }

            CommandGroup(after: .newItem) {
                Button("New Chat") {
                    openChatWindow()
                    chatContainer.newChat()
                }
                .keyboardShortcut("n")

                Button("Join Room…") {
                    focusedContactListWindowState?.joinRoom()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(focusedContactListWindowState == nil)

                Button("Bookmarks…") {
                    focusedContactListWindowState?.showBookmarks()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(focusedContactListWindowState == nil)

                Divider()

                Button("Chat Transcripts") {
                    openWindow(id: "transcripts")
                }
                .keyboardShortcut("t", modifiers: [.command, .option])

                Divider()

                Button("Import Adium Logs…") {
                    isShowingAdiumImport = true
                }
            }

            // Replaces the default Close / Close All pair: its Option-alternate Close All claims ⌥⌘W, which SwiftUI
            // then drops from any later item.
            CommandGroup(replacing: .saveItem) {
                Button("Close") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w")

                Button("Close All Chats") {
                    chatContainer.closeAll()
                    dismissWindow(id: "chat")
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .accessibilityIdentifier("close-all-chats-menu")
                .disabled(!chatContainer.hasTabs)
            }

            CommandMenu("Contact") {
                Button("Add Contact…") {
                    focusedContactListWindowState?.addContact()
                }
                .keyboardShortcut("d")
                .disabled(focusedContactListWindowState == nil)

                Divider()

                Button("Get Info") {
                    if let contactInfoRef = contactCommandTarget?.contactInfoRef {
                        openWindow(id: "contact-info", value: contactInfoRef)
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .accessibilityIdentifier("contact-menu-get-info")
                .disabled(contactCommandTarget?.contactInfoRef == nil)

                Button("History") {
                    if let target = contactCommandTarget {
                        transcriptScope.request(target.transcriptRef)
                        openWindow(id: "transcripts")
                    }
                }
                .keyboardShortcut("l")
                .accessibilityIdentifier("contact-menu-history")
                .disabled(contactCommandTarget == nil)

                Button("Send File…") {
                    if let chat = focusedChatWindowState {
                        chat.showFileImporter()
                    } else if let target = contactCommandTarget {
                        openChatAction(target.chatKey.jid, accountID: target.chatKey.accountID)
                        chatContainer.state(for: target.chatKey)?.showFileImporter()
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .accessibilityIdentifier("contact-menu-send-file")
                .disabled(contactCommandTarget == nil)

                Button("Remove Contact…") {
                    focusedContactListWindowState?.removeSelectedContact(in: environment)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .accessibilityIdentifier("contact-menu-remove")
                .disabled(!(focusedContactListWindowState?.canRemoveSelectedContact ?? false) || isShowingAdiumImport)

                Divider()

                Button("My Profile…") {
                    focusedContactListWindowState?.editProfile()
                }
                .disabled(focusedContactListWindowState == nil)
            }

            CommandMenu("Status") {
                StatusCommandsMenu(environment: environment, preferences: statusBarPreferences) {
                    openWindow(id: "contacts")
                }
            }

            CommandGroup(after: .sidebar) {
                if let state = focusedContactListWindowState {
                    ContactListViewOptionsMenu(state: state)
                    Divider()
                }
            }

            CommandGroup(replacing: .textEditing) {
                Button("Find…") {
                    if let chat = focusedChatWindowState {
                        chat.toggleSearch()
                    } else {
                        focusedContactListWindowState?.toggleSearch()
                    }
                }
                .keyboardShortcut("f")
                .disabled(focusedChatWindowState == nil && focusedContactListWindowState == nil)
            }

            CommandGroup(before: .windowList) {
                // Titled "Contact List" so it doesn't read as a duplicate of the window list's own "Contacts" entry.
                Button(focusedContactListWindowState != nil ? "Hide Contact List" : "Show Contact List") {
                    if focusedContactListWindowState != nil {
                        dismissWindow(id: "contacts")
                    } else {
                        openWindow(id: "contacts")
                    }
                }
                .keyboardShortcut("/")
                .accessibilityIdentifier("contacts-window-menu")

                Divider()

                Button("Select Next Tab") {
                    chatContainer.selectNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .accessibilityIdentifier("next-tab-menu")
                .disabled(!canCycleChatTabs)

                Button("Select Previous Tab") {
                    chatContainer.selectPreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .accessibilityIdentifier("previous-tab-menu")
                .disabled(!canCycleChatTabs)

                Divider()
            }

            CommandGroup(after: .help) {
                Button("Export Logs…") {
                    exportLogs()
                }
            }
        }

        MenuBarExtra("Ducko", systemImage: "bubble.left.and.bubble.right.fill", isInserted: $generalPreferences.showInMenuBar) {
            MenuBarStatusView()
                .environment(environment)
                .environment(themeEngine)
                .environment(statusBarPreferences)
        }

        Settings {
            PreferencesView()
                .environment(environment)
                .environment(themeEngine)
                .environment(generalPreferences)
                .environment(statusBarPreferences)
        }
    }

    /// The active conversation when the Chat window is focused, else the selected Contacts row.
    private var contactCommandTarget: ContactCommandTarget? {
        focusedChatWindowState?.commandTarget ?? focusedContactListWindowState?.commandTarget(in: environment)
    }

    private var canCycleChatTabs: Bool {
        focusedChatWindowState != nil && chatContainer.canCycleTabs
    }

    private var totalUnread: Int {
        environment.chatService.openConversations.reduce(0) { $0 + $1.unreadCount }
    }

    private func wireNotifications() {
        wireMessageAttention()
        wireFileOfferAttention()
        notificationManager.onNotificationTapped = { [chatContainer] jidString, accountID in
            chatContainer.open(jidString, accountID: accountID)
            openChatWindow()
        }
    }

    private func wireMessageAttention() {
        environment.chatService.onIncomingMessage = { message, conversation in
            let jidString = conversation.jid.description
            let contact = conversation.accountID.flatMap { environment.rosterService.contact(jidString: jidString, accountID: $0) }
            let attention = IncomingAttention.forMessage(
                message, in: conversation,
                isFromRosterContact: contact != nil,
                isInView: conversation.id == environment.chatService.activeConversationID
            )
            act(
                on: attention,
                senderName: IncomingAttention.senderName(in: conversation, rosterName: contact?.displayName, jidString: jidString),
                body: message.previewText, jidString: jidString, accountID: conversation.accountID
            )
        }
    }

    /// A file offer waits in a banner inside the chat window, so without this it would go unseen whenever that window
    /// is closed.
    private func wireFileOfferAttention() {
        environment.fileTransferService.onIncomingOffer = { offer in
            let conversation = IncomingAttention.chat(
                withSender: offer.fromJIDString, accountID: offer.accountID, among: environment.chatService.openConversations
            )
            let contact = environment.rosterService.contact(jidString: offer.fromJIDString, accountID: offer.accountID)
            let attention = IncomingAttention.forFileOffer(
                in: conversation,
                isFromRosterContact: contact != nil,
                isInView: conversation.map { $0.id == environment.chatService.activeConversationID } ?? false
            )
            act(
                on: attention,
                senderName: IncomingAttention.senderName(in: conversation, rosterName: contact?.displayName, jidString: offer.fromJIDString),
                body: "Wants to send you \(offer.fileName)", jidString: offer.fromJIDString, accountID: offer.accountID
            )
        }
    }

    private func act(on attention: IncomingAttention, senderName: String, body: String, jidString: String, accountID: UUID?) {
        if attention.opensChatQuietly, let accountID {
            openChatQuietly(withJIDString: jidString, accountID: accountID)
        }
        guard attention.notifies else { return }
        notificationManager.postMessageNotification(
            from: senderName, body: body, jidString: jidString, accountID: accountID, avatarData: nil
        )
        notificationManager.bounceDockIcon()
    }

    /// Gives the chat a tab, and a chat window to show it in, without interrupting: the tab is not switched to and the
    /// window does not take the keyboard.
    private func openChatQuietly(withJIDString jidString: String, accountID: UUID) {
        chatContainer.openInBackground(jidString, accountID: accountID)
        QuietWindow.show(identifier: "chat") { openWindow(id: "chat") } settling: { chatContainer.isOpeningQuietly = $0 }
    }

    private func exportLogs() {
        let panel = NSSavePanel()
        let dateString = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "ducko-logs-\(dateString)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try LogExporter.export(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

// MARK: - App Lifecycle Observer

/// Tells the server whether anyone can see the app (XEP-0352 CSI). A server holds typing and presence updates back
/// from a client that says it is inactive. So the app says so only while none of its windows is on screen, since one
/// that is merely behind another app's still shows who is typing and who is online.
/// Retained by `DuckoApp` for the app's lifetime, independent of any window.
@MainActor
final class AppStateObserver {
    init(accountService: AccountService) {
        let changes = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSWindow.didChangeOcclusionStateNotification
        ]
        for name in changes {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    let windows = NSApp.windows.map {
                        (isTitled: $0.styleMask.contains(.titled), isOnScreen: $0.occlusionState.contains(.visible))
                    }
                    await accountService.setAppActive(Self.isAppVisible(isActive: NSApp.isActive, windows: windows))
                }
            }
        }
    }

    /// Checks each titled window rather than the app's own occlusion state, which counts the menu bar item's window,
    /// and that window is on screen whenever the menu bar is.
    nonisolated static func isAppVisible(isActive: Bool, windows: [(isTitled: Bool, isOnScreen: Bool)]) -> Bool {
        isActive || windows.contains { $0.isTitled && $0.isOnScreen }
    }
}

// MARK: - App Delegate

/// Sends unavailable presence and `</stream:stream>` per RFC 6120 §4.4 before
/// the process exits. Without this, SIGTERM (or `app.terminate()` from the UI
/// integration test harness) leaves the server holding the resource bound for
/// 30-90 s, which collides with the next test's bind.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak static var environment: AppEnvironment?
    weak static var chatContainer: ChatContainerState?

    /// Bound on `disconnectAll`. A stuck TCP/TLS write must not be allowed to
    /// hold AppKit's terminate-later reply forever — the user can already see
    /// the app refusing to quit, and AppKit's own (~60 s) failsafe is too long.
    static let disconnectDeadline: Duration = .seconds(3)

    /// Extracted so unit tests can exercise the disconnect path without an `NSApplication` host.
    static func performShutdown(_ environment: AppEnvironment) async {
        log.info("applicationShouldTerminate fired; awaiting disconnectAll")
        await environment.accountService.disconnectAll(within: disconnectDeadline)
        log.info("disconnectAll completed (or timed out); cancelling service tasks")
        await environment.shutdown(within: disconnectDeadline)
        log.info("service shutdown completed; replying terminate")
    }

    /// With automatic tabbing on, AppKit adds Show Next/Previous Tab (⌃⇥ / ⌃⇧⇥) to the Window menu once a tabbable
    /// window opens, which collides with the chat tab commands and mangles the SwiftUI Window menu group.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.chatContainer?.stopSavingTabs()
        guard let environment = Self.environment else { return .terminateNow }
        Task { @MainActor in
            await Self.performShutdown(environment)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
