import DuckoXMPP
import Foundation

/// Bridge type for `RegistrationModule.RegistrationForm` so DuckoUI can display
/// registration forms without importing DuckoXMPP.
public struct RegistrationFormInfo: Sendable {
    public enum FormKind: Sendable {
        case legacy
        case dataForm
    }

    public let formKind: FormKind
    public let instructions: String?
    public let isRegistered: Bool
    /// The fields a legacy form asks for, in the server's order.
    public var legacyFields: [RegistrationField]
    /// Where the server sends the user to register instead.
    public let redirectURL: URL?
    public var dataForm: DataFormInfo

    public init(from form: RegistrationModule.RegistrationForm) {
        self.formKind = form.formType == .dataForm ? .dataForm : .legacy
        self.instructions = form.instructions
        self.isRegistered = form.isRegistered
        self.legacyFields = form.legacyFields.map { RegistrationField(name: $0.name, value: $0.value) }
        self.redirectURL = form.redirectURL.flatMap(URL.init(string:))
        self.dataForm = DataFormInfo(from: form.dataForm)
    }

    /// The redirect as a link the user may open, which only a web address is.
    public var redirectLink: URL? {
        redirectURL.flatMap { $0.isWebAddress ? $0 : nil }
    }

    /// Whether the form has anything to fill in, which a form that only redirects elsewhere does not.
    public var hasFields: Bool {
        switch formKind {
        case .legacy: !legacyFields.isEmpty
        case .dataForm: dataForm.fields.contains(where: \.isUserEditable)
        }
    }

    public var canSubmit: Bool {
        hasFields && hasRequiredValues
    }

    /// Whether every field that needs a value has one: every element of a legacy form, since the server needs all
    /// it asked for (XEP-0077 §3.1), and a data form's required fields.
    var hasRequiredValues: Bool {
        switch formKind {
        case .legacy: !legacyFields.contains(where: \.isMissingValue)
        case .dataForm: dataForm.hasRequiredValues
        }
    }

    /// The value the form holds for the field of that name, nil when the form has no such field.
    func value(of name: String) -> String? {
        switch formKind {
        case .legacy: legacyFields.first { $0.name == name }?.value
        case .dataForm: dataForm.fields.first { $0.variable == name }.map { $0.values.first ?? "" }
        }
    }

    /// The form with the account details typed before it was fetched filled in.
    func filling(username: String, password: String, email: String?) -> RegistrationFormInfo {
        let typed = ["username": username, "password": password, "email": email ?? ""].filter { !$0.value.isEmpty }
        var form = self
        for index in form.legacyFields.indices {
            if let value = typed[form.legacyFields[index].name] { form.legacyFields[index].value = value }
        }
        for index in form.dataForm.fields.indices where form.dataForm.fields[index].isUserEditable {
            if let value = form.dataForm.fields[index].variable.flatMap({ typed[$0] }) { form.dataForm.fields[index].values = [value] }
        }
        return form
    }

    /// Whether the server asks for nothing beyond the account details and each of them was typed, so the
    /// registration can go out without showing its form.
    var asksOnlyForAccountDetails: Bool {
        guard redirectURL == nil, hasFields, hasRequiredValues else { return false }
        let accountDetails: Set = ["username", "password", "email"]
        switch formKind {
        case .legacy:
            return legacyFields.allSatisfy { accountDetails.contains($0.name) }
        case .dataForm:
            return dataForm.fields.filter(\.isUserEditable).allSatisfy {
                accountDetails.contains($0.variable ?? "") && $0.values.contains { !$0.isBlank }
            }
        }
    }

    var submission: RegistrationModule.Submission {
        switch formKind {
        case .legacy: .legacy(legacyFields.map { RegistrationModule.LegacyField(name: $0.name, value: $0.value) })
        case .dataForm: .dataForm(dataForm.fields.map { $0.toDataFormField() })
        }
    }
}

/// One field of a legacy registration form (XEP-0077 §14.1).
public struct RegistrationField: Sendable, Identifiable, Equatable {
    /// The element name the server listed, such as `username` or `nick`.
    public let name: String
    public var value: String

    public var id: String {
        name
    }

    public var isSecret: Bool {
        name == "password"
    }

    /// Whether the field has no value yet, counting spaces alone as none, as for a data form's required field.
    public var isMissingValue: Bool {
        value.isBlank
    }

    public var label: String {
        switch name {
        case "username": "Username"
        case "nick": "Nickname"
        case "password": "Password"
        case "name": "Full Name"
        case "first": "First Name"
        case "last": "Last Name"
        case "email": "Email"
        case "address": "Address"
        case "city": "City"
        case "state": "State"
        case "zip": "Postal Code"
        case "phone": "Phone"
        case "url": "Website"
        case "date": "Date"
        case "misc": "Miscellaneous"
        case "text": "Text"
        case "key": "Key"
        default: name
        }
    }

    public init(name: String, value: String = "") {
        self.name = name
        self.value = value
    }
}

/// What creating an account led to: the new account, or a server form that asks for more.
public enum RegistrationOutcome: Sendable {
    case registered(UUID)
    case needsMoreFields(PendingRegistration)
}

/// A registration whose server asked for more than the account details. It holds the connection the form came on,
/// so its owner has to submit the completed form or cancel it.
public struct PendingRegistration: Sendable {
    /// The server's form, with the account details typed so far filled in.
    public let form: RegistrationFormInfo
    let session: RegistrationSession
    let typedUsername: String
    let typedPassword: String
    /// Creates and signs in to the account once the server has accepted the registration.
    let finish: @MainActor @Sendable (_ username: String, _ password: String) async throws -> UUID

    /// Submits the completed form, then signs in to the new account with the username and password it carries,
    /// or the ones typed before when it has none. The connection closes either way.
    public func submit(_ form: RegistrationFormInfo) async throws -> UUID {
        do {
            try await session.submit(form.submission)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        return try await finish(form.value(of: "username") ?? typedUsername, form.value(of: "password") ?? typedPassword)
    }

    /// Closes the connection without registering.
    public func cancel() async {
        await session.close()
    }
}
