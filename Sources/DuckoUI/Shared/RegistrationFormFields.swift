import DuckoCore
import SwiftUI

/// The server's part of a registration form: its instructions, the page it sends the user to instead, and its
/// fields. A CAPTCHA challenge's image sits above its answer field, and the fallback web page below the last one.
struct RegistrationFormFields: View {
    @Binding var form: RegistrationFormInfo

    var body: some View {
        if let instructions = form.shownInstructions {
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
                    Link(destination: redirectLink) {
                        Text(redirectLink.absoluteString).singleLine()
                    }
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
            DataFormFieldsView(form: $form.dataForm) { field in
                if let image = challenge(for: field)?.image {
                    CaptchaChallengeImage(image: image, hasFallback: form.captcha?.fallbackURLText != nil)
                }
            } below: { field in
                if let challenge = challenge(for: field) {
                    if !challenge.isPlayable {
                        Text("Ducko can't play this challenge. Use the web page below to answer it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if challenge.variable == form.captcha?.challenges.last?.variable {
                        captchaFooter
                    }
                }
            }
            if let captcha = form.captcha, captcha.challenges.isEmpty, captcha.fallbackURLText != nil || captcha.fallbackText != nil || captcha.isUnanswerable {
                Section {
                    captchaFooter
                }
            }
        }
    }

    private func challenge(for field: RoomConfigField) -> CaptchaChallenge? {
        form.captcha?.challenges.first { $0.fieldID == field.id }
    }

    /// The fallback web page and, when Ducko can't answer the CAPTCHA, a line saying so.
    @ContentBuilder
    private var captchaFooter: some View {
        if let captcha = form.captcha {
            if let fallbackLink = captcha.fallbackLink {
                Link(destination: fallbackLink) {
                    Text(captcha.fallbackText ?? captcha.fallbackLabel)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .help(fallbackLink.absoluteString)
                .accessibilityIdentifier("registration-captcha-fallback-link")
            } else {
                if let fallbackText = captcha.fallbackText {
                    Text(fallbackText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let fallbackURLText = captcha.fallbackURLText {
                    Text(fallbackURLText)
                        .textSelection(.enabled)
                }
            }
            if captcha.isUnanswerable {
                Label("Ducko can't answer this server's challenge.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("registration-captcha-unanswerable")
            }
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
