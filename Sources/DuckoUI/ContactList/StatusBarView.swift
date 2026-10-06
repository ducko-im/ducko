import DuckoCore
import SwiftUI

struct StatusBarView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(StatusBarPreferences.self) private var preferences
    @Bindable var windowState: ContactListWindowState

    /// The account whose avatar/name/profile the header shows and whose status leads the status line (see
    /// `IdentityResolver`). Status picks apply to every enabled account, not just this one.
    private var identityAccount: Account? {
        environment.identityAccount(preferences: preferences)
    }

    /// The identity account's ID once it has reached `.connected`; `nil` while it is still connecting.
    /// `fetchOwnProfile` no-ops until the client connects, so keying the fetch on this re-runs it when the
    /// handshake completes instead of leaving the header blank for the rest of the session.
    private var connectedAccountID: UUID? {
        guard let account = identityAccount,
              case .connected? = environment.accountService.connectionStates[account.id]
        else { return nil }
        return account.id
    }

    /// The identity account's own profile, resolved per-account so switching accounts never shows the previous
    /// account's avatar or nickname.
    private var ownProfile: ProfileInfo? {
        guard let accountID = identityAccount?.id else { return nil }
        return environment.profileService.ownProfile(for: accountID)
    }

    var body: some View {
        HStack(spacing: 8) {
            PresenceIndicator(status: headerPresence.status)

            VStack(alignment: .leading, spacing: 2) {
                identityName

                statusMenu
            }

            Spacer(minLength: 0)

            AvatarView(imageData: ownProfile?.photoData, name: displayName, size: 40)
                .accessibilityIdentifier("my-avatar")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: connectedAccountID) {
            guard let accountID = connectedAccountID else { return }
            preferences.heldIdentityAccountID = accountID
            if environment.profileService.ownProfile(for: accountID) == nil {
                await environment.profileService.fetchOwnProfile(accountID: accountID)
            }
        }
        // The Status menu's requests land here, since this window owns the sheet. `initial` covers a request made
        // while the window was closed.
        .onChange(of: preferences.requestedCustomStatus, initial: true) { _, request in
            guard let request else { return }
            windowState.customStatusPreset = request
            preferences.requestedCustomStatus = nil
        }
        .sheet(item: $windowState.customStatusPreset) { preset in
            CustomStatusSheet(
                presence: preset.presence,
                message: preset.message
            ) { presence, message, save in
                if save {
                    preferences.saveMessage(message, for: presence)
                }
                applyGlobal(presence, message: message)
            }
        }
    }

    // MARK: - Identity switcher

    @ViewBuilder
    private var identityName: some View {
        let enabledAccounts = environment.accountService.enabledAccounts
        if enabledAccounts.count > 1 {
            HeaderPullDown {
                ForEach(enabledAccounts) { account in
                    Button {
                        preferences.identityAccountID = account.id
                    } label: {
                        MenuStatusRow(
                            status: environment.presenceService.displayedPresence(for: account.id).status,
                            label: account.displayName ?? account.jid.description,
                            mark: .none
                        )
                    }
                }
            } title: {
                Text(displayName)
                    .fontWeight(.semibold)
                    .singleLine()
            }
            .accessibilityIdentifier("identity-switcher")
        } else {
            Text(displayName)
                .fontWeight(.semibold)
                .singleLine()
        }
    }

    // MARK: - Status menu

    @ViewBuilder
    private var statusMenu: some View {
        let presences = environment.presenceService.displayedPresences()
        let label = StatusSummary.label(for: headerPresence, presences: presences)
        HeaderPullDown {
            StatusMenuSections {
                globalRows(presences: presences)
            }

            Divider()

            Button("Custom…") {
                windowState.customStatusPreset = CustomStatusPreset(presence: headerPresence.status, message: headerPresence.message ?? "")
            }
        } title: {
            Text(joiningLines: label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .singleLine()
        }
        .accessibilityIdentifier("status-picker")
        // The custom `Menu` label doesn't surface its text as `kAXValue`, so
        // publish the current status label explicitly for VoiceOver and the UI
        // tests that read it back after a selection.
        .accessibilityValue(label)
    }

    @ViewBuilder
    private func globalRows(presences: StatusSummary.Presences) -> some View {
        GlobalStatusRows(presences: presences)

        if !preferences.savedMessages.isEmpty {
            Divider()
            ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
                ForEach(preferences.savedMessages(for: status), id: \.self) { message in
                    Button {
                        applyGlobal(status, message: message)
                    } label: {
                        MenuStatusRow(
                            status: status,
                            label: message,
                            mark: StatusSummary.mark(for: status, message: message, presences: presences)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Computed

    private var displayName: String {
        identityAccount?.displayName
            ?? ownProfile?.nickname
            ?? identityAccount?.jid.localPart
            ?? identityAccount?.jid.domainPart
            ?? "Me"
    }

    /// The identity account's displayed status, so a per-account override shows through and a disconnected account
    /// reads Offline.
    private var headerPresence: (status: PresenceService.PresenceStatus, message: String?) {
        environment.presenceService.displayedPresence(for: identityAccount?.id)
    }

    // MARK: - Actions

    private func applyGlobal(_ status: PresenceService.PresenceStatus, message: String?) {
        environment.applyGlobalStatus(status, message: normalize(message))
    }

    private func normalize(_ message: String?) -> String? {
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

/// A borderless header pull-down whose label is the title, a chevron, and a fill that appears on hover.
private struct HeaderPullDown<Items: View, Title: View>: View {
    @ViewBuilder let items: Items
    @ViewBuilder let title: Title
    @State private var isHovering = false

    var body: some View {
        Menu {
            items
        } label: {
            HStack(spacing: 3) {
                title
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 5)
            // Transparent until hover. The negative horizontal padding below
            // cancels this inner padding for layout so the label stays aligned
            // with the rest of the header, while the hover fill still extends past it.
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.1 : 0))
            )
            .padding(.horizontal, -5)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering = $0 }
    }
}

/// Sheet for composing a custom status: pick the presence and type a message. Reachable from the status dropdown's
/// "Custom…" item and from the Status menu.
private struct CustomStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var presence: PresenceService.PresenceStatus
    @State var message: String
    @State private var saveStatus = false
    let onApply: (PresenceService.PresenceStatus, String, Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Custom Status")
                .font(.headline)

            Picker("Status", selection: $presence) {
                ForEach(PresenceService.PresenceStatus.selectableCases, id: \.self) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 240)

            TextField("Status message", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .accessibilityIdentifier("custom-status-message-field")
                .onSubmit { applyAndDismiss() }

            Toggle("Save this status", isOn: $saveStatus)
                .frame(width: 240, alignment: .leading)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Set") {
                    applyAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func applyAndDismiss() {
        onApply(presence, message, saveStatus)
        dismiss()
    }
}
