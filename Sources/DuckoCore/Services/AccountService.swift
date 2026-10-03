import DuckoXMPP
import Foundation

@MainActor @Observable
public final class AccountService {
    // MARK: - Published State

    public private(set) var accounts: [Account] = []
    public private(set) var connectionStates: [UUID: ConnectionState] = [:]
    public private(set) var certificateWarnings: [UUID: CertificateWarning] = [:]
    public private(set) var outageInfos: [UUID: ServiceOutageInfo] = [:]

    public struct CertificateWarning: Sendable {
        public let accountJID: String
        public let previousFingerprint: String
        public let newFingerprint: String
    }

    private let store: any PersistenceStore
    private let credentialStore: any CredentialStore
    private let clientFactory: any XMPPClientFactory
    private struct AccountConnectionResources {
        var attemptID = UUID()
        var client: XMPPClient?
        var streamManagement: StreamManagementModule?
        var resumeState: SMResumeState?
        var password: String?
        var eventTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var reconnectAttempts = 0
        var redirectCount = 0
    }

    private var connectionResources: [UUID: AccountConnectionResources] = [:]
    private var isAppActive: Bool = true
    private var hasRunLaunchConnect = false
    private weak var omemoService: OMEMOService?
    var onEvent: ((XMPPEvent, UUID) -> Void)?
    var onRosterSessionStarted: ((UUID, UUID, XMPPClient) -> Void)?
    var onRosterSessionEnded: ((UUID, UUID) -> Void)?
    /// Fired at the start of a user-initiated `disconnect(accountID:)`, before the per-account event task is
    /// cancelled. `AppEnvironment` first cancels that account's dispatch tasks, then purges its feature caches
    /// synchronously, so stale events cannot repopulate cleared state. Not fired on
    /// auto-reconnecting drops, which go through `handleDisconnect` and deliver `.disconnected` normally.
    var onRequestedDisconnect: ((UUID) -> Void)?

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected(FullJID)
        case error(String)
    }

    public enum AccountServiceError: Error, LocalizedError {
        case invalidJID(String)
        case duplicateJID(String)
        case accountNotFound(UUID)
        case noStoredPassword(String)
        case notConnected(UUID)
        case moduleNotAvailable(UUID)

        public var errorDescription: String? {
            switch self {
            case let .invalidJID(string): "Invalid JID: \(string)"
            case let .duplicateJID(jid): "An account with JID \(jid) already exists"
            case let .accountNotFound(id): "Account not found: \(id)"
            case let .noStoredPassword(jid): "No stored password for \(jid)"
            case .notConnected: notConnectedDescription
            case let .moduleNotAvailable(id): "Module not available: \(id)"
            }
        }
    }

    public init(store: any PersistenceStore, credentialStore: any CredentialStore, clientFactory: any XMPPClientFactory = DefaultXMPPClientFactory()) {
        self.store = store
        self.credentialStore = credentialStore
        self.clientFactory = clientFactory
    }

    // MARK: - Lifecycle

    public func loadAccounts() async throws {
        accounts = try await store.fetchAccounts()
        for account in accounts where connectionStates[account.id] == nil {
            connectionStates[account.id] = .disconnected
        }
    }

    public func connect(accountID: UUID, password: String) async throws {
        connectionResources[accountID, default: AccountConnectionResources()].password = password
        cancelReconnect(for: accountID, resetAttempts: true)
        try await performConnect(accountID: accountID)
    }

    public func connect(accountID: UUID) async throws {
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw AccountServiceError.accountNotFound(accountID)
        }
        let jid = account.jid.description
        guard let password = credentialStore.loadPassword(for: jid) else {
            throw AccountServiceError.noStoredPassword(jid)
        }
        try await connect(accountID: accountID, password: password)
    }

    public func savePassword(accountID: UUID) async {
        if accounts.first(where: { $0.id == accountID }) == nil {
            try? await loadAccounts()
        }
        guard let account = accounts.first(where: { $0.id == accountID }),
              let password = connectionResources[accountID]?.password
        else { return }
        credentialStore.savePassword(password, for: account.jid.description)
    }

    public func savePassword(accountID: UUID, password: String) async {
        connectionResources[accountID, default: AccountConnectionResources()].password = password
        await savePassword(accountID: accountID)
    }

    public func deletePassword(accountID: UUID) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        credentialStore.deletePassword(for: account.jid.description)
    }

    public func disconnect(accountID: UUID) async {
        // Composition cancels queued dispatch and purges feature state synchronously, before connection
        // teardown suspends. Stream-loss reconnect uses handleDisconnect and preserves its distinct policy.
        onRequestedDisconnect?(accountID)
        certificateWarnings[accountID] = nil
        let detached = detachConnectionResources(for: accountID, terminal: true)
        // Published before the teardown suspends, so a status pick made meanwhile sees the account as disconnected.
        connectionStates[accountID] = .disconnected
        await detached?.client?.disconnect()
    }

    /// Detaches owned work synchronously; awaited cleanup uses the returned snapshot only.
    /// Stream loss retains credentials and retry/resume policy in the same account record.
    private func detachConnectionResources(for accountID: UUID, terminal: Bool) -> AccountConnectionResources? {
        guard let detached = connectionResources[accountID] else { return nil }
        onRosterSessionEnded?(accountID, detached.attemptID)
        detached.eventTask?.cancel()
        detached.reconnectTask?.cancel()
        if terminal {
            connectionResources.removeValue(forKey: accountID)
        } else {
            connectionResources[accountID]?.attemptID = UUID()
            connectionResources[accountID]?.client = nil
            connectionResources[accountID]?.streamManagement = nil
            connectionResources[accountID]?.eventTask = nil
            connectionResources[accountID]?.reconnectTask = nil
        }
        return detached
    }

    public func disconnectAll() async {
        // Include accounts whose delayed reconnect has no live client yet.
        let ids = connectionResources.compactMap { id, resources in
            resources.client != nil || resources.reconnectTask != nil ? id : nil
        }
        for id in ids {
            await disconnect(accountID: id)
        }
    }

    /// Bounded disconnect. `XMPPClient.disconnect()` ignores cancellation, so a stuck transport write is abandoned (not preempted) past the deadline.
    /// Safe at process exit; unsafe when callers must observe teardown completion.
    public func disconnectAll(within deadline: Duration) async {
        await runBounded(within: deadline) { [weak self] in
            await self?.disconnectAll()
        }
    }

    public func createAccount(
        jidString: String,
        displayName: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        requireTLS: Bool = true,
        connectOnLaunch: Bool = true,
        importedFrom: String? = nil
    ) async throws -> UUID {
        guard let jid = BareJID.parse(jidString) else {
            throw AccountServiceError.invalidJID(jidString)
        }
        let existing = try await store.fetchAccounts()
        if existing.contains(where: { $0.jid == jid }) {
            throw AccountServiceError.duplicateJID(jidString)
        }
        let account = Account(
            id: UUID(),
            jid: jid,
            displayName: displayName,
            isEnabled: true,
            connectOnLaunch: connectOnLaunch,
            host: host,
            port: port,
            resource: resource,
            requireTLS: requireTLS,
            importedFrom: importedFrom,
            createdAt: Date()
        )
        try await store.saveAccount(account)

        // Auto-link imported conversations whose source JID matches this account
        let imported = try await store.fetchConversations(importSourceJID: jidString)
        for conversation in imported {
            let accountID = account.id
            try await store.updateConversation(conversation.id) {
                $0.accountID = accountID
                $0.importSourceJID = nil
            }
        }

        try? await loadAccounts()
        return account.id
    }

    public func updateAccount(_ account: Account) async throws {
        try await store.saveAccount(account)
        if !account.isEnabled {
            await disconnect(accountID: account.id)
        }
        try await loadAccounts()
    }

    /// Runs `connectEnabledAccounts()` only on the first call per launch, so reopening the Contacts window doesn't
    /// reconnect accounts the user took offline. The connect runs in its own task, so cancelling the caller can't
    /// abort the launch attempt.
    public func connectEnabledAccountsOnLaunch() async {
        guard !hasRunLaunchConnect else { return }
        hasRunLaunchConnect = true
        await Task { await connectEnabledAccounts() }.value
    }

    func connectEnabledAccounts() async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.isEnabled && account.connectOnLaunch {
                let state = connectionStates[account.id]
                switch state {
                case .connected, .connecting:
                    continue
                case .disconnected, .error, .none:
                    break
                }
                group.addTask { [weak self] in
                    try? await self?.connect(accountID: account.id)
                }
            }
        }
    }

    /// Deletes the account's local data. Fully disconnects first (a no-op when already disconnected) so no live
    /// client, event task, or suspended loader can repopulate state after the delete. Use
    /// `AppEnvironment.removeAccount` / `cancelAccount` for full teardown with optional transcript deletion.
    public func deleteAccount(_ id: UUID) async throws {
        // Disconnect first so the services' connected-client/generation guards see the account gone and no
        // event task keeps delivering; composition also clears feature caches through onRequestedDisconnect.
        await disconnect(accountID: id)
        try await store.deleteAccount(id)
        deletePassword(accountID: id)
        // The OMEMO seen-device cache is delete-only — it deliberately survives reconnects, so `disconnect`
        // leaves it intact; drop it here now that the account row is gone.
        omemoService?.purgeSeenDeviceClassifications(accountID: id)
        try await loadAccounts()
    }

    // MARK: - Server Info

    /// Fetches XEP-0157 server contact addresses via disco#info.
    public func fetchServerInfo(accountID: UUID) async throws -> ServerInfo {
        guard let client = connectionResources[accountID]?.client else {
            throw AccountServiceError.notConnected(accountID)
        }
        guard let disco = await client.module(ofType: ServiceDiscoveryModule.self) else {
            return ServerInfo(contactAddresses: [])
        }
        guard let account = accounts.first(where: { $0.id == accountID }),
              let domainJID = JID.parse(account.jid.domainPart) else {
            return ServerInfo(contactAddresses: [])
        }

        let info = try await disco.queryInfo(for: domainJID)
        var addresses: [ContactAddress] = []
        for form in info.forms {
            let formType = form.first { $0.variable == "FORM_TYPE" }?.values.first
            guard formType == XMPPNamespaces.serverInfo else { continue }
            for field in form {
                guard let type = ContactAddressType(rawValue: field.variable) else { continue }
                for value in field.values {
                    addresses.append(ContactAddress(type: type, address: value))
                }
            }
        }
        return ServerInfo(contactAddresses: addresses)
    }

    // MARK: - Registration

    /// Create + connect with rollback on failure. `afterConnect` runs inside the rollback scope before the password is saved — any throw triggers cleanup.
    public func createAndConnect(
        jidString: String,
        password: String,
        host: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        requireTLS: Bool = true,
        connectOnLaunch: Bool = true,
        importedFrom: String? = nil,
        afterConnect: ((UUID) async throws -> Void)? = nil
    ) async throws -> UUID {
        let accountID = try await createAccount(
            jidString: jidString,
            host: host,
            port: port,
            resource: resource,
            requireTLS: requireTLS,
            connectOnLaunch: connectOnLaunch,
            importedFrom: importedFrom
        )
        do {
            try await connect(accountID: accountID, password: password)
            try await afterConnect?(accountID)
            await savePassword(accountID: accountID)
            try await loadAccounts()
        } catch {
            await disconnect(accountID: accountID)
            try? await store.unlinkConversations(for: accountID, restoreImportSourceJID: jidString)
            try? await store.deleteContacts(for: accountID)
            try? await deleteAccount(accountID)
            throw error
        }
        return accountID
    }

    /// Whether the error represents an XMPP authentication failure (wrong password, etc.).
    public nonisolated static func isAuthenticationError(_ error: Error) -> Bool {
        if case .authenticationFailed = error as? XMPPClientError { return true }
        return false
    }

    /// Registers a new account on a server via XEP-0077 pre-auth registration.
    public func registerAccount(
        domain: String,
        username: String,
        password: String,
        email: String? = nil,
        host: String? = nil,
        port: UInt16 = 5222,
        afterConnect: ((UUID) async throws -> Void)? = nil
    ) async throws -> UUID {
        try await XMPPRegistrationClient.register(
            domain: domain,
            username: username,
            password: password,
            email: email,
            host: host,
            port: port
        )
        return try await createAndConnect(jidString: "\(username)@\(domain)", password: password, afterConnect: afterConnect)
    }

    /// Changes the password for a connected account via XEP-0077.
    public func changePassword(accountID: UUID, newPassword: String) async throws {
        let regModule = try await registrationModule(for: accountID)
        try await regModule.changePassword(newPassword: newPassword)
        connectionResources[accountID]?.password = newPassword
        await savePassword(accountID: accountID)
    }

    /// Sends a cancel-registration IQ to the server (XEP-0077) without deleting local data.
    public func cancelRegistration(accountID: UUID) async throws {
        let regModule = try await registrationModule(for: accountID)
        try await regModule.cancelRegistration()
    }

    /// Retrieves a registration form from a server without authenticating (XEP-0077).
    public func retrieveRegistrationForm(
        domain: String, host: String? = nil, port: UInt16 = 5222
    ) async throws -> RegistrationFormInfo {
        let form = try await XMPPRegistrationClient.retrieveForm(domain: domain, host: host, port: port)
        return RegistrationFormInfo(from: form)
    }

    /// Retrieves a registration form from a connected server or component (XEP-0077).
    public func retrieveRegistrationForm(accountID: UUID, from jid: String? = nil) async throws -> RegistrationFormInfo {
        let regModule = try await registrationModule(for: accountID)
        let form = try await regModule.retrieveForm(from: parseOptionalJID(jid))
        return RegistrationFormInfo(from: form)
    }

    /// Submits a legacy registration form to a connected server or component (XEP-0077).
    public func submitRegistration(
        accountID: UUID, username: String, password: String, email: String? = nil, to jid: String? = nil
    ) async throws {
        let regModule = try await registrationModule(for: accountID)
        try await regModule.submitLegacy(username: username, password: password, email: email, to: parseOptionalJID(jid))
    }

    /// Submits a data form registration to a connected server or component (XEP-0077).
    public func submitRegistrationDataForm(
        accountID: UUID, fields: [RoomConfigField], to jid: String? = nil
    ) async throws {
        let regModule = try await registrationModule(for: accountID)
        try await regModule.submitDataForm(fields.map { $0.toDataFormField() }, to: parseOptionalJID(jid))
    }

    // MARK: - Wiring

    func setOMEMOService(_ service: OMEMOService) {
        omemoService = service
    }

    // MARK: - Client Access

    private func registrationModule(for accountID: UUID) async throws -> RegistrationModule {
        guard let client = connectionResources[accountID]?.client else {
            throw AccountServiceError.notConnected(accountID)
        }
        guard let module = await client.module(ofType: RegistrationModule.self) else {
            throw AccountServiceError.moduleNotAvailable(accountID)
        }
        return module
    }

    private func parseOptionalJID(_ jid: String?) -> JID? {
        jid.flatMap { JID.parse($0) }
    }

    public func client(for accountID: UUID) -> XMPPClient? {
        connectionResources[accountID]?.client
    }

    /// Returns the client only when state is `.connected`. Gates against the race where the client is set before
    /// `client.connect()` resolves — that race would otherwise leak `XMPPClientError.notConnected` instead of the
    /// service's typed `notConnected`. Race window narrows to before the caller's next await; not airtight without a
    /// re-check inside `XMPPClient.module(...)`.
    public func connectedClient(for accountID: UUID) -> XMPPClient? {
        guard case .connected = connectionStates[accountID] else { return nil }
        return connectionResources[accountID]?.client
    }

    /// True when at least one account is `.connected`. Drives `WelcomeView`'s contacts-window transition and `ContactListView`'s `accessibilityValue` sentinel.
    public var hasAnyConnectedAccount: Bool {
        connectionStates.values.contains {
            if case .connected = $0 { return true }
            return false
        }
    }

    public var enabledAccounts: [Account] {
        accounts.filter(\.isEnabled)
    }

    public func tlsInfo(for accountID: UUID) -> TLSInfo? {
        connectionResources[accountID]?.client?.tlsInfo
    }

    /// Persists the new certificate fingerprint and clears the warning.
    public func trustNewCertificate(for accountID: UUID) {
        guard let warning = certificateWarnings[accountID],
              var account = accounts.first(where: { $0.id == accountID }) else { return }
        account.certificateFingerprint = warning.newFingerprint
        certificateWarnings[accountID] = nil
        Task {
            try? await store.saveAccount(account)
            try? await loadAccounts()
        }
    }

    /// Notifies all connected clients of app active/inactive state for CSI.
    public func setAppActive(_ active: Bool) async {
        isAppActive = active
        for resources in connectionResources.values {
            if let client = resources.client { await applyCSIState(to: client) }
        }
    }

    /// Rejects the new certificate, clears the warning, and disconnects.
    public func rejectNewCertificate(for accountID: UUID) async {
        certificateWarnings[accountID] = nil
        cancelReconnect(for: accountID, resetAttempts: true)
        await connectionResources[accountID]?.client?.disconnect()
        connectionStates[accountID] = .disconnected
    }

    // MARK: - Private: Connection

    private func performConnect(accountID: UUID) async throws {
        guard connectionResources[accountID] != nil else { throw CancellationError() }
        let attemptID = UUID()
        connectionResources[accountID]?.attemptID = attemptID
        connectionResources[accountID]?.redirectCount = 0
        // Published before the store fetch, so a requested teardown sees the attempt while the fetch is pending.
        connectionStates[accountID] = .connecting

        let account: Account
        do {
            let storedAccounts = try await store.fetchAccounts()
            guard let found = storedAccounts.first(where: { $0.id == accountID }) else {
                throw AccountServiceError.accountNotFound(accountID)
            }
            try Task.checkCancellation()
            account = found
        } catch {
            // Only the current attempt settles its own `.connecting`. A connect that superseded it, or a teardown such
            // as rejecting a certificate, has already published the state.
            if connectionResources[accountID]?.attemptID == attemptID, case .connecting = connectionStates[accountID] {
                connectionStates[accountID] = Task.isCancelled ? .disconnected : .error(error.localizedDescription)
            }
            throw error
        }
        guard connectionResources[accountID]?.attemptID == attemptID else { throw CancellationError() }

        let previousSMState = connectionResources[accountID]?.resumeState
        connectionResources[accountID]?.resumeState = nil
        let (client, sm) = await buildClient(account: account, previousSMState: previousSMState)
        guard !Task.isCancelled, connectionResources[accountID]?.attemptID == attemptID else {
            await client.disconnect()
            throw CancellationError()
        }
        connectionResources[accountID]?.client = client
        connectionResources[accountID]?.streamManagement = sm
        onRosterSessionStarted?(accountID, attemptID, client)

        startEventConsumption(for: accountID, client: client)

        do {
            try await connect(client, account: account, resumeState: previousSMState)
        } catch {
            onRosterSessionEnded?(accountID, attemptID)
            guard connectionResources[accountID]?.attemptID == attemptID else { throw error }
            // Restore SM state so the next retry can attempt resumption
            if let smState = sm.resumeState {
                connectionResources[accountID]?.resumeState = smState
            }
            connectionStates[accountID] = .error(error.localizedDescription)
            throw error
        }
    }

    private func connect(_ client: XMPPClient, account: Account, resumeState: SMResumeState?) async throws {
        if let location = resumeState?.location {
            let parts = location.split(separator: ":")
            let host = String(parts[0])
            let port = parts.count > 1 ? UInt16(parts[1]) ?? 5222 : 5222
            try await client.connect(host: host, port: port)
        } else if let host = account.host, let port = account.port {
            try await client.connect(host: host, port: UInt16(port))
        } else {
            try await client.connect()
        }
    }

    private func buildClient(
        account: Account, previousSMState: SMResumeState?,
        requireTLSOverride: Bool? = nil
    ) async -> (XMPPClient, StreamManagementModule) {
        await clientFactory.makeClient(
            account: account,
            password: connectionResources[account.id]?.password ?? "",
            previousSMState: previousSMState,
            requireTLSOverride: requireTLSOverride,
            omemoService: omemoService
        )
    }

    // MARK: - Private: Event Consumption

    private func applyCSIState(to client: XMPPClient) async {
        guard let csiModule = await client.module(ofType: CSIModule.self) else { return }
        if isAppActive {
            try? await csiModule.sendActive()
        } else {
            try? await csiModule.sendInactive()
        }
    }

    private func startEventConsumption(for accountID: UUID, client: XMPPClient) {
        connectionResources[accountID]?.eventTask?.cancel()

        connectionResources[accountID]?.eventTask = Task { [weak self] in
            for await event in client.events {
                guard let self, !Task.isCancelled, connectionResources[accountID]?.client === client else { return }
                handleEvent(event, accountID: accountID)
            }
        }
    }

    private func handleEvent(_ event: XMPPEvent, accountID: UUID) {
        switch event {
        case let .connected(jid), let .streamResumed(jid):
            connectionStates[accountID] = .connected(jid)
            connectionResources[accountID]?.reconnectAttempts = 0
            connectionResources[accountID]?.redirectCount = 0
            checkCertificateFingerprint(accountID: accountID)
            if let client = connectionResources[accountID]?.client {
                Task { await applyCSIState(to: client) }
            }
        case let .disconnected(reason):
            outageInfos[accountID] = nil
            handleDisconnect(reason, accountID: accountID)
        case let .authenticationFailed(message):
            connectionStates[accountID] = .error(message)
        case let .serviceOutageReceived(info):
            outageInfos[accountID] = info
        case .messageReceived, .presenceReceived, .iqReceived,
             .rosterUpdated,
             .presenceUpdated, .presenceSubscriptionRequest,
             .presenceSubscriptionApproved, .presenceSubscriptionRevoked,
             .messageCarbonReceived, .messageCarbonSent,
             .archivedMessagesLoaded,
             .chatStateChanged, .deliveryReceiptReceived,
             .chatMarkerReceived, .messageCorrected, .messageRetracted, .messageModerated, .messageError,
             .roomJoined, .roomOccupantJoined, .roomOccupantLeft,
             .roomOccupantNickChanged, .roomSubjectChanged,
             .roomInviteReceived, .roomMessageReceived, .mucPrivateMessageReceived, .roomDestroyed,
             .mucSelfPingFailed,
             .jingleFileTransferReceived, .jingleFileTransferCompleted,
             .jingleFileTransferFailed, .jingleFileTransferProgress,
             .jingleChecksumReceived,
             .pepItemsPublished, .pepItemsRetracted,
             .vcardAvatarHashReceived,
             .blockListLoaded, .contactBlocked, .contactUnblocked,
             .omemoDeviceListReceived, .omemoEncryptedMessageReceived, .omemoSessionEstablished, .omemoSessionAdvanced, .omemoRecipientsPartial,
             .oobIQOfferReceived:
            break
        }

        onEvent?(event, accountID)
    }

    // MARK: - Disconnect Messages

    /// The message for a stream error: the server's non-blank text, else a phrase for the condition.
    public nonisolated static func streamErrorMessage(condition: XMPPStreamError?, text: String?) -> String {
        if let text, !text.allSatisfy(\.isWhitespace) { return text }
        return condition?.displayText ?? "The server closed the connection"
    }

    public nonisolated static func connectionLostMessage(_ detail: String) -> String {
        "Connection lost: \(detail)"
    }

    // MARK: - Private: Disconnect Handling

    private func handleDisconnect(_ reason: DisconnectReason, accountID: UUID) {
        let detached = detachConnectionResources(for: accountID, terminal: false)
        switch reason {
        case .requested:
            connectionResources[accountID]?.resumeState = nil
            connectionResources[accountID]?.redirectCount = 0
            connectionStates[accountID] = .disconnected
        case let .streamError(condition, text):
            connectionResources[accountID]?.resumeState = detached?.streamManagement?.resumeState
            connectionStates[accountID] = .error(Self.streamErrorMessage(condition: condition, text: text))
            scheduleReconnect(accountID: accountID)
        case let .connectionLost(detail):
            connectionResources[accountID]?.resumeState = detached?.streamManagement?.resumeState
            connectionStates[accountID] = .error(Self.connectionLostMessage(detail))
            scheduleReconnect(accountID: accountID)
        case let .redirect(host, port):
            let count = (connectionResources[accountID]?.redirectCount ?? 0) + 1
            if count > 3 {
                connectionResources[accountID]?.redirectCount = 0
                connectionStates[accountID] = .error("The server redirected too many times")
            } else {
                connectionResources[accountID]?.redirectCount = count
                redirectToHost(host: host, port: port, accountID: accountID)
            }
        }
    }

    // MARK: - Private: Certificate Fingerprint

    private func checkCertificateFingerprint(accountID: UUID) {
        guard let client = connectionResources[accountID]?.client,
              let currentFingerprint = client.tlsInfo?.certificateSHA256,
              let account = accounts.first(where: { $0.id == accountID })
        else { return }

        let previousFingerprint = account.certificateFingerprint

        if let previous = previousFingerprint, previous != currentFingerprint {
            // Changed fingerprint — defer persistence until user explicitly trusts
            certificateWarnings[accountID] = CertificateWarning(
                accountJID: account.jid.description,
                previousFingerprint: previous,
                newFingerprint: currentFingerprint
            )
        } else if previousFingerprint == nil {
            // First connection (TOFU) — persist silently
            var updated = account
            updated.certificateFingerprint = currentFingerprint
            Task {
                try? await store.saveAccount(updated)
                try? await loadAccounts()
            }
        }
    }

    // MARK: - Private: Reconnection

    private func cancelReconnect(for accountID: UUID, resetAttempts: Bool) {
        connectionResources[accountID]?.reconnectTask?.cancel()
        connectionResources[accountID]?.reconnectTask = nil
        if resetAttempts {
            connectionResources[accountID]?.reconnectAttempts = 0
        }
    }

    private func redirectToHost(host: String, port: UInt16?, accountID: UUID) {
        let attemptID = UUID()
        connectionResources[accountID]?.attemptID = attemptID
        connectionStates[accountID] = .connecting
        connectionResources[accountID]?.reconnectTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            do {
                let stored = try await store.fetchAccounts()
                guard !Task.isCancelled, connectionResources[accountID]?.attemptID == attemptID else { return }
                guard let account = stored.first(where: { $0.id == accountID }) else {
                    throw AccountServiceError.accountNotFound(accountID)
                }
                // Force TLS for redirects to prevent plaintext credential exposure via see-other-host injection.
                let (client, sm) = await buildClient(account: account, previousSMState: nil, requireTLSOverride: true)
                guard !Task.isCancelled, connectionResources[accountID]?.attemptID == attemptID else {
                    await client.disconnect()
                    return
                }
                connectionResources[accountID]?.client = client
                connectionResources[accountID]?.streamManagement = sm
                onRosterSessionStarted?(accountID, attemptID, client)
                startEventConsumption(for: accountID, client: client)
                try await client.connect(host: host, port: port ?? 5222)
            } catch {
                onRosterSessionEnded?(accountID, attemptID)
                guard !Task.isCancelled, connectionResources[accountID]?.attemptID == attemptID else { return }
                connectionStates[accountID] = .error(error.localizedDescription)
            }
        }
    }

    private func scheduleReconnect(accountID: UUID) {
        let attempt = connectionResources[accountID]?.reconnectAttempts ?? 0
        guard attempt < 5 else { return }

        connectionResources[accountID]?.reconnectAttempts = attempt + 1
        let delay = min(pow(2.0, Double(attempt)), 30.0) + Double.random(in: 0 ... 5)

        connectionResources[accountID]?.reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            try? await self?.performConnect(accountID: accountID)
        }
    }
}
