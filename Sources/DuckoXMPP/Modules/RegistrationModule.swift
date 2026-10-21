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

    /// One element of a legacy registration form (XEP-0077 §14.1).
    public struct LegacyField: Sendable, Equatable {
        public let name: String
        public var value: String

        public init(name: String, value: String = "") {
            self.name = name
            self.value = value
        }
    }

    public struct RegistrationForm: Sendable {
        public let formType: FormType
        public let instructions: String?
        public let isRegistered: Bool
        /// The elements a legacy form asks for, in the server's order, with any value it filled in.
        public let legacyFields: [LegacyField]
        /// Where the server sends the user to register instead (`jabber:x:oob`).
        public let redirectURL: String?
        /// The server's `jabber:x:data` form, empty for a legacy form.
        public let dataForm: DataForm

        public init(
            formType: FormType,
            instructions: String?,
            isRegistered: Bool,
            legacyFields: [LegacyField] = [],
            redirectURL: String? = nil,
            dataForm: DataForm = DataForm()
        ) {
            self.formType = formType
            self.instructions = instructions
            self.isRegistered = isRegistered
            self.legacyFields = legacyFields
            self.redirectURL = redirectURL
            self.dataForm = dataForm
        }
    }

    /// What a registration sends back: every legacy field the form asked for, or the completed data form.
    public enum Submission: Sendable {
        case legacy([LegacyField])
        case dataForm([DataFormField])
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

    /// Submits a registration to the server or a specific entity.
    public func submit(_ submission: Submission, to jid: JID? = nil) async throws {
        guard let context = state.withLock({ $0.context }) else {
            throw RegistrationError.notConnected
        }

        var iq = XMPPIQ(type: .set, id: context.generateID())
        if let jid { iq.to = jid }
        iq.element.addChild(Self.buildRegistrationQuery(submission))
        _ = try await context.sendIQ(iq)
        log.info("Submitted a registration")
        log.debug("The registration went to \(jid?.description ?? "the server")")
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

    /// The element names a legacy form can ask for (XEP-0077 §14.1).
    static let legacyFieldNames: Set<String> = [
        "username", "nick", "password", "name", "first", "last", "email", "address", "city", "state", "zip",
        "phone", "url", "date", "misc", "text", "key"
    ]

    static func parseForm(_ element: XMLElement) -> RegistrationForm {
        let instructions = element.childText(named: "instructions")
        let isRegistered = element.child(named: "registered") != nil
        let redirectURL = element.child(named: "x", namespace: XMPPNamespaces.oob)?.childText(named: "url")

        if let formElement = element.child(named: "x", namespace: XMPPNamespaces.dataForms) {
            return RegistrationForm(
                formType: .dataForm,
                instructions: instructions,
                isRegistered: isRegistered,
                redirectURL: redirectURL,
                dataForm: parseDataForm(formElement)
            )
        }

        let legacyFields = element.children.compactMap { node -> LegacyField? in
            guard case let .element(child) = node,
                  child.namespace == nil || child.namespace == XMPPNamespaces.register,
                  legacyFieldNames.contains(child.name)
            else { return nil }
            return LegacyField(name: child.name, value: child.textContent ?? "")
        }
        return RegistrationForm(
            formType: .legacy,
            instructions: instructions,
            isRegistered: isRegistered,
            legacyFields: legacyFields,
            redirectURL: redirectURL
        )
    }

    /// Builds the XEP-0077 `<query>` element.
    static func buildRegistrationQuery(_ submission: Submission) -> XMLElement {
        var query = XMLElement(name: "query", namespace: XMPPNamespaces.register)
        switch submission {
        case let .legacy(fields):
            for field in fields {
                var element = XMLElement(name: field.name)
                element.addText(field.value)
                query.addChild(element)
            }
        case let .dataForm(fields):
            query.addChild(buildSubmitForm(fields))
        }
        return query
    }
}
