import DuckoCore
import SwiftUI

/// The server's registration form, for a new account whose server asks for more than the username, password and
/// email. When the server refuses the form, a fresh one takes its place, keeping what was typed. Any other failure
/// closes the sheet and hands its error back. However the sheet closes, the registration's connection closes with it.
struct PendingRegistrationSheet: View {
    /// A registration to show the form of.
    struct Item: Identifiable {
        let id = UUID()
        let pending: PendingRegistration
    }

    /// Whether the sheet has closed, for a submission that outlives it to close the fresh form it fetched. A submission
    /// keeps the instance it started with, since the view's state can't be read once the sheet is gone.
    @MainActor
    private final class Lifetime {
        var hasEnded = false
    }

    @Environment(\.dismiss) private var dismiss
    @State private var pending: PendingRegistration
    @State private var form: RegistrationFormInfo
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @State private var lifetime = Lifetime()
    /// Gets the error of a failure that ended the registration.
    private let onFailure: (String) -> Void

    init(pending: PendingRegistration, onFailure: @escaping (String) -> Void) {
        self._pending = State(initialValue: pending)
        self._form = State(initialValue: pending.form)
        self._errorMessage = State(initialValue: pending.rejection?.localizedDescription)
        self.onFailure = onFailure
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                RegistrationFormFields(form: $form)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .accessibilityIdentifier("register-server-form-error")
                }
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("register-server-form")

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("register-cancel-button")

                Spacer()

                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Register")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canSubmit || isSubmitting)
                .accessibilityIdentifier("register-server-form-submit")
            }
            .padding()
        }
        .frame(width: 400)
        .frame(minHeight: 300)
        .onDisappear {
            lifetime.hasEnded = true
            let pending = pending
            Task { await pending.cancel() }
        }
    }

    /// Whether it succeeds or fails, the registration's connection is closed, so a refusal needs a fresh form on a new
    /// one. Once the sheet has closed, which closes the connection, neither a refusal nor that close is reported. A
    /// fresh form that arrives after that is closed too. A failed sign-in after the server accepted is still reported.
    private func submit() async {
        let lifetime = lifetime
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await pending.submit(form)
            dismiss()
        } catch {
            let isRejected = AccountService.isRegistrationRejected(error)
            if lifetime.hasEnded, isRejected || AccountService.isRegistrationConnectionClosed(error) { return }
            if isRejected {
                let fresh = try? await pending.reopen(after: form, error: error)
                if lifetime.hasEnded {
                    await fresh?.cancel()
                    return
                }
                if let fresh {
                    pending = fresh
                    form = fresh.form
                    errorMessage = error.localizedDescription
                    AccessibilityNotification.Announcement("The server sent a new form").post()
                    return
                }
            }
            onFailure(error.localizedDescription)
            dismiss()
        }
    }
}
