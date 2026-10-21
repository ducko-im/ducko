import DuckoCore
import SwiftUI

struct ContactListWindow: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openChat) private var openChat
    @State private var state = ContactListWindowState()
    @State private var chromeHeight: CGFloat = 0

    @AppStorage(ContactListSizingDefaults.maxWidthKey, store: PreferencesDefaults.store)
    private var maxWidthPreference = ContactListSizingDefaults.defaultMaxWidth

    /// Enabled account IDs in a stable order, so the per-account load `.task(id:)`
    /// re-fires on membership change but not on reorder.
    private var enabledAccountIDs: [UUID] {
        environment.accountService.enabledAccounts
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
    }

    /// The user's Maximum Width preference, clamped to the slider's valid range
    /// (and guarded against a non-finite persisted value) so a stray stored
    /// number can't collapse or invalidate the window frame.
    private var clampedMaxWidth: CGFloat {
        CGFloat(ContactListSizing.clampMaxWidth(maxWidthPreference))
    }

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            // The chrome above the list. Its measured height is published via
            // `ChromeHeightKey` and fed to `ContactListTableView`, so when it
            // grows or shrinks (⌘F search, a subscription-request or room-invite
            // banner) the resize rides the coordinator's animation instead of
            // `.contentMinSize` snapping the window outside the transaction.
            VStack(spacing: 0) {
                StatusBarView(windowState: state)

                Divider()

                if state.isSearching {
                    ContactSearchField(state: state)
                    Divider()
                }

                SubscriptionRequestBanner()

                RoomInviteBanner(isEditingNickname: $state.isEditingInviteNickname)

                if let notice = state.rosterNotice {
                    DismissibleBanner(message: notice, dismissalLabel: "Dismiss notice", dismissalShortcut: .cancelAction) {
                        state.rosterNotice = nil
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("roster-notice")
                }
            }
            // Pin the chrome to its natural height so a short window can never
            // compress it — otherwise the measured `ChromeHeightKey` shrinks,
            // the coordinator drives the window shorter still, and the header
            // collapses in a feedback loop.
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ChromeHeightKey.self, value: proxy.size.height)
                }
            }

            ContactListView(windowState: state, chromeHeight: chromeHeight)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
        }
        // Share the coordinator's lower width bound so AppKit's min clamp can't
        // fight an animated sub-floor width. Match the height minimum to the
        // measured chrome, not a static floor: the coordinator sizes the window
        // to `chrome + list`, so a taller minimum would — via the frame's
        // default centering — spill the "me" header under the title bar. `.top`
        // pins the header so any shortfall clips the list below instead.
        .frame(
            minWidth: min(ContactListWidthMetrics.floor, clampedMaxWidth),
            minHeight: chromeHeight,
            alignment: .top
        )
        .onPreferenceChange(ChromeHeightKey.self) { chromeHeight = $0 }
        .focusedSceneValue(\.contactListWindowState, state)
        // Launch connect is owned by `ContentView`, not here — this task only loads cached data.
        .task(id: enabledAccountIDs) {
            for accountID in enabledAccountIDs {
                try? await environment.chatService.loadConversations(for: accountID)
                try? await environment.rosterService.loadContacts(for: accountID)
            }
        }
        // Idle monitoring is a single global monitor that broadcasts to every
        // connected account, so it is started once rather than per account.
        .task {
            environment.presenceService.startIdleMonitoring()
        }
        .sheet(isPresented: $state.isShowingAddContact) {
            AddContactSheet { state.presentRosterNotice($0, accountID: $1, environment: environment) }
        }
        .sheet(isPresented: $state.isShowingJoinRoom) {
            RoomJoinDialog { jidString, accountID in
                openChat(jidString, accountID: accountID)
            }
        }
        .sheet(isPresented: $state.isShowingBookmarks) {
            NavigationStack {
                BookmarkListView()
            }
            .frame(minWidth: 400, minHeight: 300)
        }
        .sheet(isPresented: $state.isShowingProfile) {
            ProfileEditView()
        }
        .confirmationDialog(
            "Remove \(state.pendingRemoval?.displayName ?? "")?",
            isPresented: Binding(
                get: { state.pendingRemoval != nil },
                set: { if !$0 { state.pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: state.pendingRemoval
        ) { contact in
            Button("Remove Contact", role: .destructive) {
                Task { await state.confirmRemoval(contact, environment: environment) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Certificate Changed",
            isPresented: Binding(
                get: { !environment.accountService.certificateWarnings.isEmpty },
                set: { newValue in
                    if !newValue, let id = environment.accountService.certificateWarnings.keys.first {
                        Task { await environment.accountService.rejectNewCertificate(for: id) }
                    }
                }
            )
        ) {
            Button("Trust New Certificate") {
                if let id = environment.accountService.certificateWarnings.keys.first {
                    environment.accountService.trustNewCertificate(for: id)
                }
            }
            Button("Disconnect", role: .destructive) {
                if let id = environment.accountService.certificateWarnings.keys.first {
                    Task { await environment.accountService.rejectNewCertificate(for: id) }
                }
            }
        } message: {
            if let warning = environment.accountService.certificateWarnings.values.first {
                Text("The TLS certificate for \(warning.accountJID) has changed.\n\nPrevious: \(warning.previousFingerprint)\nNew: \(warning.newFingerprint)")
            }
        }
        .signInSecurityAlert()
    }
}

/// Publishes the measured height of the chrome stack above the list so
/// `ContactListTableView`'s coordinator can size the window absolutely
/// (`chromeHeight + listHeight`) and animate chrome show/hide as an input
/// change rather than a synchronous `.contentMinSize` snap.
struct ChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Search field revealed by ⌘F (Find). Takes focus on appear and dismisses on
/// Escape, clearing the query so the list returns to its full state.
private struct ContactSearchField: View {
    @Bindable var state: ContactListWindowState
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                // Center the glyph in the same 8-pt column as the contact
                // status dots so the icon and query text line up with the
                // dot/name columns of the rows below.
                .frame(width: 8)

            TextField("Search", text: $state.searchText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { state.endSearch() }
                .accessibilityIdentifier("contact-search-field")

            if !state.searchText.isEmpty {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Defer focus one main-actor turn: the window resizes as this field is
        // inserted (chrome grows), and that frame change clears first responder
        // if focus is set synchronously in the same pass.
        .onAppear {
            Task { @MainActor in isFocused = true }
        }
    }
}
