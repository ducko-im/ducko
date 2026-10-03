import DuckoCore
import SwiftUI

struct RegistrationFormSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let accountID: UUID
    @State private var formInfo: RegistrationFormInfo?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var submitSuccess = false

    @State private var username = ""
    @State private var password = ""
    @State private var email = ""

    @State private var dataFormFields: [RoomConfigField] = []

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView("Loading registration form…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedContent
                    // Only the settled states carry this, so automation can tell
                    // a loaded sheet from one still waiting on the server.
                    .accessibilityIdentifier("registration-form-content")
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if formInfo != nil, !submitSuccess {
                    Button("Submit") {
                        submit()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isSubmitting)
                    .accessibilityIdentifier("registration-submit-button")
                }
            }
            .padding()
        }
        .frame(width: 400)
        .frame(minHeight: 300)
        .task {
            await loadForm()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("registration-form-sheet")
    }

    @ViewBuilder
    private var loadedContent: some View {
        if let errorMessage, formInfo == nil {
            ContentUnavailableView(
                "Failed to load registration form",
                systemImage: "exclamationmark.triangle",
                description: Text(errorMessage)
            )
        } else if let formInfo {
            formContent(formInfo)
        }
    }

    private func formContent(_ info: RegistrationFormInfo) -> some View {
        Form {
            if info.isRegistered {
                Section {
                    Label("You are currently registered on this server.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            if let instructions = info.instructions, !instructions.isEmpty {
                Section("Instructions") {
                    Text(instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            switch info.formKind {
            case .legacy:
                legacyFormFields(info)
            case .dataForm:
                Section("Fields") {
                    DataFormFieldsView(fields: $dataFormFields)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if submitSuccess {
                Label("Registration submitted successfully.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
    }

    private func legacyFormFields(_ info: RegistrationFormInfo) -> some View {
        Section("Registration") {
            if info.hasUsername {
                TextField("Username", text: $username)
                    .accessibilityIdentifier("registration-username-field")
            }
            if info.hasPassword {
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("registration-password-field")
            }
            if info.hasEmail {
                TextField("Email", text: $email)
                    .accessibilityIdentifier("registration-email-field")
            }
        }
    }

    private var canSubmit: Bool {
        guard let formInfo else { return false }
        switch formInfo.formKind {
        case .legacy:
            return !username.isEmpty || !password.isEmpty || !email.isEmpty
        case .dataForm:
            return !dataFormFields.isEmpty
        }
    }

    // MARK: - Actions

    private func loadForm() async {
        do {
            let info = try await environment.accountService.retrieveRegistrationForm(accountID: accountID)
            formInfo = info
            dataFormFields = info.dataFormFields
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func submit() {
        guard let formInfo else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                switch formInfo.formKind {
                case .legacy:
                    try await environment.accountService.submitRegistration(
                        accountID: accountID,
                        username: username,
                        password: password,
                        email: email.isEmpty ? nil : email
                    )
                case .dataForm:
                    try await environment.accountService.submitRegistrationDataForm(
                        accountID: accountID,
                        fields: dataFormFields
                    )
                }
                submitSuccess = true
                isSubmitting = false
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
