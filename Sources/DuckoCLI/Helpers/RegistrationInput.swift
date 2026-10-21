import DuckoCore
import Foundation

/// Shows the server's registration form, prompts for its fields and submits it. The connection is closed on every
/// exit. A form that only sends the user to a web page ends with an error once it has been shown.
func completeRegistration(_ pending: PendingRegistration, formatter: any CLIFormatter) async throws -> UUID {
    print(formatter.formatRegistrationForm(pending.form))
    var form = pending.form
    do {
        guard form.hasFields else { throw CLIError.registrationRedirected }
        print("\nThe server asks for more details (press Enter to keep a value):")
        try promptForRegistrationValues(&form, formatter: formatter)
    } catch {
        await pending.cancel()
        throw error
    }
    return try await pending.submit(form)
}

/// Prompts for every field of a registration form, legacy or data form. Pressing Enter keeps a field's value.
func promptForRegistrationValues(_ form: inout RegistrationFormInfo, formatter: any CLIFormatter) throws {
    switch form.formKind {
    case .legacy:
        for index in form.legacyFields.indices {
            try promptForValue(of: &form.legacyFields[index])
        }
    case .dataForm:
        try promptForDataFormValues(&form.dataForm.fields, formatter: formatter)
    }
}

/// Reads one legacy field, hidden for the password, until it has a value: the server needs every element it asked
/// for.
private func promptForValue(of field: inout RegistrationField) throws {
    while true {
        let typed: String
        if field.isSecret {
            guard let secret = try CredentialHelper.readHiddenLine(prompt: "\(field.label): ") else {
                if field.isMissingValue { throw CLIError.noHiddenInput(field: field.label) }
                return
            }
            typed = secret
        } else {
            print("\(field.label) [\(field.value)]: ", terminator: "")
            guard let line = readLine() else {
                if field.isMissingValue { throw CLIError.inputEnded(field: field.label) }
                return
            }
            typed = line.trimmingCharacters(in: .whitespaces)
        }
        if !typed.isEmpty { field.value = typed }
        guard field.isMissingValue else { return }
        print("\(field.label) is required.")
    }
}
