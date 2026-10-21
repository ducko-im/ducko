import DuckoCore
import SwiftUI

/// The server's part of a registration form: its instructions, the page it sends the user to instead, and its
/// fields.
struct RegistrationFormFields: View {
    @Binding var form: RegistrationFormInfo

    var body: some View {
        if let instructions = form.instructions, !instructions.isEmpty {
            Section("Instructions") {
                Text(instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("registration-instructions")
            }
        }

        if let redirectURL = form.redirectURL {
            Section("Register on the Web") {
                if let redirectLink = form.redirectLink {
                    Link(redirectLink.absoluteString, destination: redirectLink)
                        .accessibilityIdentifier("registration-redirect-link")
                } else {
                    Text(redirectURL.absoluteString)
                        .textSelection(.enabled)
                }
            }
        }

        switch form.formKind {
        case .legacy:
            if !form.legacyFields.isEmpty {
                Section("Registration") {
                    ForEach($form.legacyFields) { $field in
                        legacyField($field)
                            .accessibilityIdentifier("registration-\(field.name)-field")
                    }
                }
            }
        case .dataForm:
            DataFormFieldsView(form: $form.dataForm)
        }
    }

    /// A legacy form's every element is required, since the server needs all it asked for.
    @ViewBuilder
    private func legacyField(_ field: Binding<RegistrationField>) -> some View {
        if field.wrappedValue.isSecret {
            SecureField(text: field.value, prompt: Text("Required")) {
                Text(field.wrappedValue.label)
            }
        } else {
            TextField(text: field.value, prompt: Text("Required")) {
                Text(field.wrappedValue.label)
            }
        }
    }
}
