import AppKit
import DuckoCore
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ThemeEngine.self) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var profile = ProfileInfo()
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isSelectingPhoto = false
    @State private var profileLoaded = false
    @State private var isPublishingAvatar = false
    @State private var avatarErrorMessage: String?
    @State private var avatarImage: NSImage?

    private var account: Account? {
        environment.accountService.accounts.first { $0.isEnabled }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                profileForm
            }
        }
        .frame(minWidth: 450, minHeight: 500)
        .accessibilityIdentifier("profile-edit-view")
        .task {
            await loadProfile()
        }
    }

    // MARK: - Form

    private var profileForm: some View {
        VStack(spacing: 0) {
            Form {
                nameSection
                contactSection
                addressSection
                organizationSection
                otherSection
                photoSection
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .padding(.horizontal)
            }

            footerButtons
        }
    }

    // MARK: - Name Section

    private var nameSection: some View {
        Section("Name") {
            TextField("Full Name", text: binding(for: \.fullName))
                .accessibilityIdentifier("profile-fullname-field")
            TextField("Nickname", text: binding(for: \.nickname))
                .accessibilityIdentifier("profile-nickname-field")
            TextField("Given Name", text: binding(for: \.givenName))
                .accessibilityIdentifier("profile-given-name-field")
            TextField("Family Name", text: binding(for: \.familyName))
                .accessibilityIdentifier("profile-family-name-field")
            TextField("Middle Name", text: binding(for: \.middleName))
            TextField("Prefix", text: binding(for: \.namePrefix))
            TextField("Suffix", text: binding(for: \.nameSuffix))
        }
    }

    // MARK: - Contact Section

    @ViewBuilder
    private var contactSection: some View {
        Section("Email") {
            ForEach($profile.emails) { $email in
                let index = profile.emails.firstIndex(where: { $0.id == email.id }) ?? 0
                HStack {
                    TextField("Email", text: $email.address)
                        .accessibilityIdentifier("profile-email-field-\(index)")
                    entryTypePicker($email.types)
                    removeButton { profile.emails.removeAll { $0.id == email.id } }
                }
            }
            addButton("Add Email") { profile.emails.append(ProfileInfo.EmailEntry()) }
        }

        Section("Telephone") {
            ForEach($profile.telephones) { $tel in
                let index = profile.telephones.firstIndex(where: { $0.id == tel.id }) ?? 0
                HStack {
                    TextField("Phone", text: $tel.number)
                        .accessibilityIdentifier("profile-phone-field-\(index)")
                    entryTypePicker($tel.types)
                    removeButton { profile.telephones.removeAll { $0.id == tel.id } }
                }
            }
            addButton("Add Phone") { profile.telephones.append(ProfileInfo.TelephoneEntry()) }
        }
    }

    // MARK: - Address Section

    private var addressSection: some View {
        Section("Addresses") {
            ForEach($profile.addresses) { $adr in
                VStack(alignment: .leading) {
                    HStack {
                        entryTypePicker($adr.types)
                        Spacer()
                        removeButton { profile.addresses.removeAll { $0.id == adr.id } }
                    }
                    TextField("Street", text: optionalBinding($adr.street))
                    TextField("City", text: optionalBinding($adr.locality))
                    TextField("Region", text: optionalBinding($adr.region))
                    TextField("Postal Code", text: optionalBinding($adr.postalCode))
                    TextField("Country", text: optionalBinding($adr.country))
                }
            }
            addButton("Add Address") { profile.addresses.append(ProfileInfo.AddressEntry()) }
        }
    }

    // MARK: - Organization Section

    private var organizationSection: some View {
        Section("Organization") {
            TextField("Organization", text: binding(for: \.organization))
                .accessibilityIdentifier("profile-org-field")
            TextField("Title", text: binding(for: \.title))
                .accessibilityIdentifier("profile-title-field")
            TextField("Role", text: binding(for: \.role))
        }
    }

    // MARK: - Other Section

    private var otherSection: some View {
        Section("Other") {
            TextField("URL", text: binding(for: \.url))
            TextField("Birthday", text: binding(for: \.birthday))
            TextField("Note", text: binding(for: \.note))
        }
    }

    // MARK: - Photo Section

    private var photoSection: some View {
        Section("Photo") {
            VStack(spacing: 12) {
                avatarPreview
                    .accessibilityIdentifier("profile-avatar-preview")

                if let avatarErrorMessage {
                    Text(avatarErrorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                HStack(spacing: 12) {
                    Button("Change Photo") {
                        isSelectingPhoto = true
                    }
                    .disabled(isPublishingAvatar)
                    .accessibilityIdentifier("profile-change-photo-button")

                    if profile.photoData != nil {
                        Button("Remove Photo", role: .destructive) {
                            Task { await removePhoto() }
                        }
                        .disabled(isPublishingAvatar)
                        .accessibilityIdentifier("profile-remove-photo-button")
                    }
                }

                if isPublishingAvatar {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isSelectingPhoto,
            allowedContentTypes: [.png, .jpeg, .gif],
            allowsMultipleSelection: false
        ) { result in
            Task { await handlePhotoSelected(result) }
        }
        .onChange(of: profile.photoData) {
            avatarImage = profile.photoData.flatMap { AvatarImageDecoder.decode($0, maxPixelSize: 256) }
        }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        let size: CGFloat = 80
        let clipShape = theme.current.avatarShape.clipShape(size: size)

        if let avatarImage {
            Image(nsImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(clipShape)
        } else {
            Text(profileInitials)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(
                    LinearGradient(
                        colors: [.blue, .blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: clipShape
                )
        }
    }

    private var profileInitials: String {
        let name = profile.fullName ?? ""
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        if !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        return "?"
    }

    // MARK: - Footer

    private var footerButtons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("profile-cancel-button")

            Spacer()

            Button("Save") {
                Task { await saveProfile() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaving || !profileLoaded)
            .accessibilityIdentifier("profile-save-button")
        }
        .padding()
    }

    // MARK: - Actions

    private func loadProfile() async {
        guard let accountID = account?.id else {
            isLoading = false
            return
        }
        await environment.profileService.fetchOwnProfile(accountID: accountID)
        if let fetched = environment.profileService.ownProfile(for: accountID) {
            profile = fetched
            avatarImage = fetched.photoData.flatMap { AvatarImageDecoder.decode($0, maxPixelSize: 256) }
        }
        // Set profileLoaded even when ownProfile is nil (no vCard on server) to
        // allow first-time profile creation. Only stays false if we have no account.
        profileLoaded = true
        isLoading = false
    }

    private func handlePhotoSelected(_ result: Result<[URL], Error>) async {
        guard case let .success(urls) = result, let url = urls.first else { return }
        guard let accountID = account?.id else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let imageData = try? Data(contentsOf: url) else { return }

        let utType = UTType(filenameExtension: url.pathExtension)
        let mimeType = utType?.preferredMIMEType ?? "image/png"

        isPublishingAvatar = true
        avatarErrorMessage = nil
        defer { isPublishingAvatar = false }

        do {
            try await environment.avatarService.publishAvatar(
                imageData: imageData, mimeType: mimeType, accountID: accountID
            )
            profile.photoData = imageData
            profile.photoType = mimeType
            avatarImage = AvatarImageDecoder.decode(imageData, maxPixelSize: 256)
        } catch {
            avatarErrorMessage = error.localizedDescription
        }
    }

    private func removePhoto() async {
        guard let accountID = account?.id else { return }

        isPublishingAvatar = true
        avatarErrorMessage = nil
        defer { isPublishingAvatar = false }

        do {
            try await environment.avatarService.removeAvatar(accountID: accountID)
            profile.photoData = nil
            profile.photoType = nil
            avatarImage = nil
        } catch {
            avatarErrorMessage = error.localizedDescription
        }
    }

    private func saveProfile() async {
        guard let accountID = account?.id else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            try await environment.profileService.publishProfile(profile, accountID: accountID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func binding(for keyPath: WritableKeyPath<ProfileInfo, String?>) -> Binding<String> {
        Binding(
            get: { profile[keyPath: keyPath] ?? "" },
            set: { newValue in
                profile[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { newValue in
                binding.wrappedValue = newValue.isEmpty ? nil : newValue
            }
        )
    }

    private func entryTypePicker(_ types: Binding<[ProfileInfo.EntryType]>) -> some View {
        Picker("", selection: Binding(
            get: { types.wrappedValue.first },
            set: { newValue in
                types.wrappedValue = newValue.map { [$0] } ?? []
            }
        )) {
            Text("").tag(ProfileInfo.EntryType?.none)
            Text("Home").tag(ProfileInfo.EntryType?.some(.home))
            Text("Work").tag(ProfileInfo.EntryType?.some(.work))
        }
        .frame(width: 80)
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
    }

    private func addButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
    }
}
