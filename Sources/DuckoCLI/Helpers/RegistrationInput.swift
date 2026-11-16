import DuckoCore
import Foundation

/// One fetched registration form and how to send it, so one prompt loop serves a registration before sign-in and one
/// sent to a server or component once signed in.
protocol RegistrationAttempt {
    associatedtype Outcome
    var form: RegistrationFormInfo { get }
    func submit(_ form: RegistrationFormInfo) async throws -> Outcome
    /// Fetches a fresh form after the server refused `rejected` with `error`, keeping what was typed into it.
    func refetch(after rejected: RegistrationFormInfo, error: any Error) async throws -> Self
    /// Gives up without submitting.
    func cancel() async
}

extension PendingRegistration: RegistrationAttempt {
    func refetch(after rejected: RegistrationFormInfo, error: any Error) async throws -> PendingRegistration {
        try await reopen(after: rejected, error: error)
    }
}

/// A registration with a server or component, sent over a signed-in account's connection.
struct SignedInRegistration: RegistrationAttempt {
    let form: RegistrationFormInfo
    let accountService: AccountService
    let accountID: UUID
    /// The server or component registered with, nil for the account's own server.
    let jid: String?

    func submit(_ form: RegistrationFormInfo) async throws {
        try await accountService.submitRegistration(accountID: accountID, form: form, to: jid)
    }

    func refetch(after rejected: RegistrationFormInfo, error: any Error) async throws -> SignedInRegistration {
        let fresh = try await accountService.reopenRegistrationForm(accountID: accountID, from: jid, after: rejected)
        return SignedInRegistration(form: fresh, accountService: accountService, accountID: accountID, jid: jid)
    }

    func cancel() async {}
}

/// The most registrations one command sends, counting one Ducko sent itself before showing the form.
private let maxRegistrationSubmissions = 3

/// Prints the server's refusal of the registration Ducko sent itself, if any, then shows the form, prompts for its
/// fields and submits it. The connection is closed on every exit.
func completeRegistration(_ pending: PendingRegistration, formatter: any CLIFormatter) async throws -> UUID {
    if let rejection = pending.rejection {
        print(formatter.formatError(rejection))
    }
    return try await promptAndSubmitRegistration(
        pending, submissionsMade: pending.rejection == nil ? 0 : 1,
        intro: "\nThe server asks for more details (press Enter to keep a value):", formatter: formatter
    )
}

/// Shows the form, prompts for its fields and submits it. A refusal from the server shows its error and a fresh form,
/// up to `maxRegistrationSubmissions` submissions counting `submissionsMade`. A form that only sends the user to a web
/// page, or whose CAPTCHA Ducko can't answer, ends with an error once it has been shown. The CAPTCHA's images are
/// written to files for the user to open while answering, and deleted once the user has answered or given up.
func promptAndSubmitRegistration<Attempt: RegistrationAttempt>(
    _ first: Attempt, submissionsMade: Int, intro: String, formatter: any CLIFormatter
) async throws -> Attempt.Outcome {
    var attempt = first
    var submissions = submissionsMade
    while true {
        print(formatter.formatRegistrationForm(attempt.form))
        var form = attempt.form
        do {
            if form.captcha?.isUnanswerable == true { throw CLIError.captchaUnanswerable }
            guard form.hasFields || form.captcha?.proofOfWork?.answer != nil else { throw CLIError.registrationRedirected }
            let images = try CaptchaImageFiles.write(form.captcha)
            defer { images?.remove() }
            for image in images?.images ?? [] {
                print("CAPTCHA image for \(image.variable): \(image.url.path)")
            }
            // Piped output is buffered, and the user needs the path before the prompt waits for an answer.
            fflush(stdout)
            if form.hasFields {
                print(intro)
                try promptForSubmittableValues(&form, formatter: formatter)
            }
        } catch {
            await attempt.cancel()
            throw error
        }
        do {
            return try await attempt.submit(form)
        } catch {
            submissions += 1
            guard AccountService.isRegistrationRejected(error), submissions < maxRegistrationSubmissions else { throw error }
            print(formatter.formatError(error))
            attempt = try await attempt.refetch(after: form, error: error)
        }
    }
}

/// Prompts for every field, then again for the CAPTCHA's challenges while too few of them are answered. Without a
/// terminal, hidden answers can't be read, so when every challenge is hidden it throws instead of asking again.
private func promptForSubmittableValues(_ form: inout RegistrationFormInfo, formatter: any CLIFormatter) throws {
    try promptForRegistrationValues(&form, formatter: formatter)
    while !form.canSubmit, let captcha = form.captcha, !captcha.challenges.isEmpty {
        let variables = Set(captcha.challenges.map(\.variable))
        var challengeFields = form.dataForm.fields.filter { $0.variable.map(variables.contains) ?? false }
        if isatty(STDIN_FILENO) == 0, let hidden = challengeFields.first, challengeFields.allSatisfy({ $0.type == "text-private" }) {
            throw CLIError.noHiddenInput(field: hidden.displayLabel)
        }
        print(captcha.answersRequired.map { "Answer at least \($0) of the challenges." } ?? "Answer the challenge.")
        try promptForDataFormValues(&challengeFields, formatter: formatter)
        for field in challengeFields {
            guard let index = form.dataForm.fields.firstIndex(where: { $0.id == field.id }) else { continue }
            form.dataForm.fields[index] = field
        }
    }
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
            guard let line = readLine() else { throw CLIError.inputEnded(field: field.label) }
            typed = line.trimmingCharacters(in: .whitespaces)
        }
        if !typed.isEmpty { field.value = typed }
        guard field.isMissingValue else { return }
        print("\(field.label) is required.")
    }
}
