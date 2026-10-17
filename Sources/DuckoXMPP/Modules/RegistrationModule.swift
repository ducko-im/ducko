import Logging
import struct os.OSAllocatedUnfairLock

private let log = Logger(label: "im.ducko.xmpp.registration")

/// Implements XEP-0077 In-Band Registration — provides post-auth operations
/// like password change and account cancellation on connected clients.
public final class RegistrationModule: XMPPModule, Sendable {
    // MARK: - Types

    public enum FormType: Sendable, Equatable {
        case legacy
        case dataForm
    }

    public struct RegistrationForm: Sendable {
        public let formType: FormType
        public let instructions: String?
        public let isRegistered: Bool
        public let hasUsername: Bool
        public let hasPassword: Bool
        public let hasEmail: Bool
        public let dataFormFields: [DataFormField]

        public init(
            formType: FormType,
            instructions: String?,
            isRegistered: Bool,
            hasUsername: Bool,
            hasPassword: Bool,
            hasEmail: Bool,
            dataFormFields: [DataFormField]
        ) {
            self.formType = formType
            self.instructions = instructions
            self.isRegistered = isRegistered
            self.hasUsername = hasUsername
            self.hasPassword = hasPassword
            self.hasEmail = hasEmail
            self.dataFormFields = dataFormFields
        }
    }

    public enum RegistrationError: Error {
        case notConnected
        case registrationNotSupported
    }

    // MARK: - State

    private struct State {
        var context: ModuleContext?
    }

    private let state: OSAllocatedUnfairLock<State>

    public var features: [String] {
        [XMPPNamespaces.register]
    }

    public init() {
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    public func setUp(_ context: ModuleContext) {
        state.withLock { $0.context = context }
    }

    // MARK: - Public API

    /// Retrieves the registration form from the server or a specific entity.
    public func retrieveForm(from jid: JID? = nil) async throws -> RegistrationForm {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .get, id: context.generateID())
        if let jid { iq.to = jid }
        let query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
        iq.element.addChild(query)

        guard let result = try await context.sendIQ(iq) else {
            throw RegistrationError.registrationNotSupported
        }

        log.info("Retrieved a registration form")
        log.debug("The registration form came from \(jid?.description ?? "the server")")
        return Self.parseForm(result)
    }

    public func submitLegacy(
        username: String,
        password: String,
        email: String? = nil,
        to jid: JID? = nil
    ) async throws {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        if let jid { iq.to = jid }

        let query = Self.buildRegistrationQuery(username: username, password: password, email: email)
        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
        log.info("Submitted a legacy registration")
        log.debug("The legacy registration went to \(jid?.description ?? "the server")")
    }

    /// Submits a data form registration.
    public func submitDataForm(_ fields: [DataFormField], to jid: JID? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        if let jid { iq.to = jid }

        var query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
        let form = buildSubmitForm(fields)
        query.addChild(form)

        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
        log.info("Submitted a data form registration")
        log.debug("The data form registration went to \(jid?.description ?? "the server")")
    }

    /// Changes the password for the currently authenticated account.
    public func changePassword(newPassword: String) async throws {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .set, id: context.generateID())

        var query = XMLElement(name: "query", namespace: XMPPNamespaces.register)

        var usernameEl = XMLElement(name: "username")
        usernameEl.addText(context.connectedJID()?.bareJID.localPart ?? "")
        query.addChild(usernameEl)

        var passwordEl = XMLElement(name: "password")
        passwordEl.addText(newPassword)
        query.addChild(passwordEl)

        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
        log.info("Password changed")
    }

    /// Cancels (unregisters) the currently authenticated account.
    public func cancelRegistration() async throws {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .set, id: context.generateID())

        var query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
        let remove = XMLElement(name: "remove")
        query.addChild(remove)

        iq.element.addChild(query)
        _ = try await context.sendIQ(iq)
        log.info("Registration cancelled")
    }

    static func parseForm(_ element: XMLElement) -> RegistrationForm {
        let instructions = element.childText(named: "instructions")
        let isRegistered = element.child(named: "registered") != nil

        if let formElement = element.child(named: "x", namespace: XMPPNamespaces.dataForms) {
            let fields = parseDataForm(formElement)
            return RegistrationForm(
                formType: .dataForm,
                instructions: instructions,
                isRegistered: isRegistered,
                hasUsername: fields.contains { $0.variable == "username" },
                hasPassword: fields.contains { $0.variable == "password" },
                hasEmail: fields.contains { $0.variable == "email" },
                dataFormFields: fields
            )
        }

        // Legacy form
        return RegistrationForm(
            formType: .legacy,
            instructions: instructions,
            isRegistered: isRegistered,
            hasUsername: element.child(named: "username") != nil,
            hasPassword: element.child(named: "password") != nil,
            hasEmail: element.child(named: "email") != nil,
            dataFormFields: []
        )
    }

    /// Builds the XEP-0077 `<query>` element.
    static func buildRegistrationQuery(username: String, password: String, email: String?) -> XMLElement {
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.register)

        var usernameEl = XMLElement(name: "username")
        usernameEl.addText(username)
        query.addChild(usernameEl)

        var passwordEl = XMLElement(name: "password")
        passwordEl.addText(password)
        query.addChild(passwordEl)

        if let email {
            var emailEl = XMLElement(name: "email")
            emailEl.addText(email)
            query.addChild(emailEl)
        }

        return query
    }
}
