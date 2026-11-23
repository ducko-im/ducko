import DuckoCore
import SwiftUI

struct ContactInfoView: View {
    @Bindable var state: ContactInfoWindowState
    @State private var isConfirmingRemove = false

    var body: some View {
        Form {
            identitySection
            rosterSection
            vCardSection
            actionsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 480)
        .accessibilityIdentifier("contact-info-window")
        .task(id: state.ref) {
            await state.load()
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(spacing: 8) {
                AvatarView(imageData: state.profile?.photoData ?? state.contact?.avatarData, name: state.displayName, size: 80)

                Text(state.displayName)
                    .font(.title3.weight(.semibold))

                Text(state.jid)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(spacing: 4) {
                    PresenceIndicator(display: state.presenceDisplay)
                    Text(state.statusMessage ?? state.presenceDisplay.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Roster

    @ViewBuilder
    private var rosterSection: some View {
        if let contact = state.contact {
            Section("Roster") {
                HStack {
                    TextField("Nickname", text: $state.nickname)
                        .accessibilityIdentifier("contact-info-nickname-field")
                        .onSubmit { Task { await state.rename() } }
                    Button("Save") {
                        Task { await state.rename() }
                    }
                }

                if !contact.groups.isEmpty {
                    LabeledContent("Groups", value: contact.groups.joined(separator: ", "))
                }

                LabeledContent("Subscription", value: subscriptionLabel(contact.subscription))
                Text(subscriptionExplanation(contact.subscription))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.canRequestPresence {
                    Button("Request Presence") {
                        Task { await state.requestPresence() }
                    }
                    .accessibilityIdentifier("contact-info-request-presence")
                }
            }
        }
    }

    // MARK: - vCard

    @ViewBuilder
    private var vCardSection: some View {
        if state.isLoadingProfile {
            Section("Profile") {
                ProgressView()
            }
        } else if let profile = state.profile {
            let rows = profileRows(profile)
            if !rows.isEmpty {
                Section("Profile") {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }
        } else if let error = state.profileError {
            Section("Profile") {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        if let notice = state.rosterNotice {
            Section {
                DismissibleBanner(message: notice, dismissalLabel: "Dismiss notice", dismissalShortcut: .cancelAction) {
                    state.rosterNotice = nil
                }
                .containerAccessibilityIdentifier("contact-info-roster-notice")
            }
        }
        if let contact = state.contact {
            Section {
                Button(contact.isBlocked ? "Unblock" : "Block") {
                    Task { await state.toggleBlock() }
                }
                .accessibilityIdentifier("contact-info-block")

                Button("Remove Contact", role: .destructive) {
                    isConfirmingRemove = true
                }
                .accessibilityIdentifier("contact-info-remove")
                .disabled(state.isRemoving)
            }
            .confirmationDialog(
                "Remove \(state.displayName)?",
                isPresented: $isConfirmingRemove,
                titleVisibility: .visible
            ) {
                Button("Remove Contact", role: .destructive) {
                    Task { await state.remove() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Helpers

    private func subscriptionLabel(_ subscription: Contact.Subscription) -> String {
        switch subscription {
        case .none: "None"
        case .to: "To"
        case .from: "From"
        case .both: "Both"
        }
    }

    private func subscriptionExplanation(_ subscription: Contact.Subscription) -> String {
        switch subscription {
        case .both: "You and this contact share presence with each other."
        case .to: "You receive this contact's presence."
        case .from: "This contact receives your presence, but you don't receive theirs."
        case .none: "No presence is shared in either direction."
        }
    }

    private func profileRows(_ profile: ProfileInfo) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let fullName = profile.fullName, !fullName.isEmpty { rows.append(("Full Name", fullName)) }
        for email in profile.emails where !email.address.isEmpty {
            rows.append(("Email", email.address))
        }
        for tel in profile.telephones where !tel.number.isEmpty {
            rows.append(("Phone", tel.number))
        }
        if let org = profile.organization, !org.isEmpty { rows.append(("Organization", org)) }
        if let title = profile.title, !title.isEmpty { rows.append(("Title", title)) }
        if let role = profile.role, !role.isEmpty { rows.append(("Role", role)) }
        if let url = profile.url, !url.isEmpty { rows.append(("URL", url)) }
        if let birthday = profile.birthday, !birthday.isEmpty { rows.append(("Birthday", birthday)) }
        if let note = profile.note, !note.isEmpty { rows.append(("Note", note)) }
        return rows
    }
}
