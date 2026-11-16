import DuckoXMPP
import Foundation

public extension AccountService {
    /// Registers a new account on a server via XEP-0077 pre-auth registration. The server's form is fetched first, on
    /// the connection the registration goes out on, and its proof of work answered. When it asks for nothing beyond
    /// the username, password and email, and each was typed, they are submitted and the account is created and signed
    /// in to. Otherwise the form comes back to be completed. When the server rejects that submission, a fresh form
    /// comes back instead, carrying the refusal. The account is created allowing PLAIN, because the registration
    /// already gave this server the password over TLS, so PLAIN reveals nothing more. Its first verified SCRAM sign-in
    /// turns that off.
    func registerAccount(
        domain: String,
        username: String,
        password: String,
        email: String? = nil,
        host: String? = nil,
        port: UInt16 = 5222,
        afterConnect: ((UUID) async throws -> Void)? = nil
    ) async throws -> RegistrationOutcome {
        let registration = RegistrationRequest(
            domain: domain, username: username, password: password, email: email, host: host, port: port, afterConnect: afterConnect
        )
        let pending = try await openPendingRegistration(registration, carrying: nil, rejection: nil)
        guard pending.form.asksOnlyForAccountDetails else { return .needsMoreFields(pending) }
        do {
            return try await .registered(pending.submit(pending.form))
        } catch let error as XMPPRegistrationClient.RegistrationClientError {
            guard case .registrationFailed = error else { throw error }
            return try await .needsMoreFields(pending.reopen(after: pending.form, error: error))
        }
    }

    /// Whether the server refused a registration, so a fresh form can be fetched and filled in again: before sign-in
    /// its error reply, and once signed in its stanza error.
    nonisolated static func isRegistrationRejected(_ error: any Error) -> Bool {
        if error is XMPPStanzaError { return true }
        guard case .registrationFailed = error as? XMPPRegistrationClient.RegistrationClientError else { return false }
        return true
    }

    /// Whether a registration's connection closed before the server answered, as cancelling the registration closes it.
    nonisolated static func isRegistrationConnectionClosed(_ error: any Error) -> Bool {
        guard case .connectionClosed = error as? XMPPRegistrationClient.RegistrationClientError else { return false }
        return true
    }

    /// Retrieves a registration form from a server without authenticating (XEP-0077), with its proof of work answered.
    func retrieveRegistrationForm(
        domain: String, host: String? = nil, port: UInt16 = 5222
    ) async throws -> RegistrationFormInfo {
        let session = try await openRegistrationSession(domain, host, port)
        do {
            let form = try await session.fetchForm()
            await session.close()
            return await prepareRegistrationForm(form, prefixFallback: domain, allowsSkippingImage: true)
        } catch {
            await session.close()
            throw error
        }
    }

    /// Retrieves a registration form from a connected server or component (XEP-0077), with its proof of work answered.
    func retrieveRegistrationForm(accountID: UUID, from jid: String? = nil) async throws -> RegistrationFormInfo {
        try await fetchRegistrationForm(accountID: accountID, from: jid, allowsSkippingImage: true)
    }

    /// Fetches a fresh form from a connected server or component after it refused `rejected`. It keeps what was typed
    /// except the challenge answers, and asks for any image again.
    func reopenRegistrationForm(accountID: UUID, from jid: String? = nil, after rejected: RegistrationFormInfo) async throws -> RegistrationFormInfo {
        try await fetchRegistrationForm(accountID: accountID, from: jid, allowsSkippingImage: false).carryingValues(from: rejected)
    }

    /// Submits a completed registration form to a connected server or component (XEP-0077). A form carrying a password
    /// goes out only over an encrypted stream.
    func submitRegistration(accountID: UUID, form: RegistrationFormInfo, to jid: String? = nil) async throws {
        let regModule = try await registrationModule(for: accountID)
        if form.carriesPassword {
            try requireEncryptedStream(accountID: accountID)
        }
        try await regModule.submit(form.submission, to: parseOptionalJID(jid))
    }
}

extension AccountService {
    /// What a pre-auth registration was started with, kept to fetch a fresh form after a rejection.
    struct RegistrationRequest {
        let domain: String
        let username: String
        let password: String
        let email: String?
        let host: String?
        let port: UInt16
        let afterConnect: ((UUID) async throws -> Void)?
    }

    /// Refuses to go on unless the account's stream is encrypted, before a password is sent on it.
    func requireEncryptedStream(accountID: UUID) throws {
        guard tlsInfo(for: accountID) != nil else { throw AccountServiceError.unencryptedConnection }
    }

    /// Fetches a connected server's or component's form and answers its proof of work. An answer whose form names no
    /// `from` JID starts with `jid` or, for the account's own server, its domain.
    private func fetchRegistrationForm(accountID: UUID, from jid: String?, allowsSkippingImage: Bool) async throws -> RegistrationFormInfo {
        let regModule = try await registrationModule(for: accountID)
        let form = try await regModule.retrieveForm(from: parseOptionalJID(jid))
        let prefixFallback = jid ?? accounts.first { $0.id == accountID }?.jid.domainPart ?? ""
        return await prepareRegistrationForm(form, prefixFallback: prefixFallback, allowsSkippingImage: allowsSkippingImage)
    }

    /// Bridges a fetched form and answers its proof of work. A cancelled task cancels the solver.
    func prepareRegistrationForm(
        _ form: RegistrationModule.RegistrationForm, prefixFallback: String, allowsSkippingImage: Bool
    ) async -> RegistrationFormInfo {
        await RegistrationFormInfo(from: form).answeringProofOfWork(prefixFallback: prefixFallback, allowsSkippingImage: allowsSkippingImage)
    }

    /// Opens a registration's connection and fetches its form, filled in with the typed account details. A form
    /// fetched after `rejection` carries over what was typed into `rejected` and asks for its image.
    private func openPendingRegistration(
        _ registration: RegistrationRequest, carrying rejected: RegistrationFormInfo?, rejection: (any Error)?
    ) async throws -> PendingRegistration {
        let session = try await openRegistrationSession(registration.domain, registration.host, registration.port)
        var form: RegistrationFormInfo
        do {
            let fetched = try await session.fetchForm()
            form = await prepareRegistrationForm(fetched, prefixFallback: registration.domain, allowsSkippingImage: rejected == nil)
                .filling(username: registration.username, password: registration.password, email: registration.email)
            try Task.checkCancellation()
        } catch {
            await session.close()
            throw error
        }
        if let rejected {
            form = form.carryingValues(from: rejected)
        }
        return PendingRegistration(
            form: form, session: session, typedUsername: registration.username, typedPassword: registration.password, rejection: rejection
        ) { rejected, error in
            try await self.openPendingRegistration(registration, carrying: rejected, rejection: error)
        } finish: { username, password in
            try await self.createAndConnect(
                jidString: "\(username)@\(registration.domain)",
                password: password,
                host: registration.host,
                port: registration.host == nil ? nil : Int(registration.port),
                allowsPLAIN: true,
                afterConnect: registration.afterConnect
            )
        }
    }
}
