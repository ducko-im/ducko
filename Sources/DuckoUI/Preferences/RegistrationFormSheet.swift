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
            formContent(isRegistered: formInfo.isRegistered)
        }
    }

    private func formContent(isRegistered: Bool) -> some View {
        Form {
            if isRegistered {
                Section {
                    Label("You are currently registered on this server.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }

            if let form = Binding($formInfo) {
                RegistrationFormFields(form: form)
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

    private var canSubmit: Bool {
        formInfo?.canSubmit ?? false
    }

    // MARK: - Actions

    private func loadForm() async {
        do {
            formInfo = try await environment.accountService.retrieveRegistrationForm(accountID: accountID)
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
                try await environment.accountService.submitRegistration(accountID: accountID, form: formInfo)
                submitSuccess = true
                isSubmitting = false
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}
