import DuckoXMPP
import Foundation

/// Tracks how far each account's encryption setup got on its current session, so an encrypted chat can say when it is
/// incomplete or refused, and retries it on request (XEP-0384).
public extension OMEMOService {
    /// How far the account's setup got on its current session, or nil before its first session and after a requested
    /// teardown.
    func setupState(accountID: UUID) -> OMEMOSetupState? {
        setupStates[accountID]
    }

    /// The account's setup problem as the encrypted chat with `conversationJID` shows it: incomplete or refused, unless
    /// the user dismissed it there since the account's last failed attempt.
    func setupProblem(accountID: UUID, conversationJID: String) -> OMEMOSetupState? {
        guard dismissedSetupProblems[accountID]?.contains(conversationJID) != true else { return nil }
        switch setupStates[accountID] {
        case .incomplete: return .incomplete
        case .refused: return .refused
        case .pending, .complete, .none: return nil
        }
    }

    func dismissSetupProblem(accountID: UUID, conversationJID: String) {
        dismissedSetupProblems[accountID, default: []].insert(conversationJID)
    }

    /// Takes the events that move an account's setup state in the order the account delivers them, before each is
    /// handled on a task of its own, so a fast outcome is never overwritten by the `.connected` before it.
    internal func receiveSetupEvent(_ event: XMPPEvent, accountID: UUID) {
        if case .connected = event {
            setupStates[accountID] = .pending
        } else if case let .omemoSetupChanged(status) = event {
            retryingSetupAccounts.remove(accountID)
            switch status {
            case .complete:
                setupStates[accountID] = .complete
            case .incomplete:
                setupStates[accountID] = .incomplete
                dismissedSetupProblems.removeValue(forKey: accountID)
            case .refused:
                setupStates[accountID] = .refused
                dismissedSetupProblems.removeValue(forKey: accountID)
            }
        } else if case .disconnected = event {
            // The state stays for a resume, which tells from it whether the session still needs setting up.
            retryingSetupAccounts.remove(accountID)
        }
    }

    /// Forgets the account's setup state but keeps what the user dismissed. A requested teardown needs this because its
    /// `.disconnected` may never reach the services.
    internal func clearSetupState(accountID: UUID) {
        setupStates.removeValue(forKey: accountID)
        retryingSetupAccounts.remove(accountID)
    }

    /// Forgets what the user dismissed for a deleted account.
    internal func forgetSetupDismissals(accountID: UUID) {
        dismissedSetupProblems.removeValue(forKey: accountID)
    }

    /// Tries the account's incomplete or refused setup again, at once.
    @discardableResult
    func retrySetup(accountID: UUID) async -> OMEMOSetupRetryOutcome {
        guard let client = accountService?.connectedClient(for: accountID) else { return .notConnected }
        guard setupStates[accountID] == .incomplete || setupStates[accountID] == .refused else { return .notNeeded }
        guard let module = await client.module(ofType: OMEMOModule.self), accountService?.connectedClient(for: accountID) === client else {
            return .notConnected
        }
        guard module.retrySetup() else { return .notNeeded }
        retryingSetupAccounts.insert(accountID)
        return .started
    }

    /// Returns once the account's first setup attempt on its session has had its outcome. Returns at once when the
    /// session runs none, or without a connected session.
    func awaitSetupAttempt(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let module = await client.module(ofType: OMEMOModule.self) else {
            return
        }
        await module.awaitSetupAttempt()
    }

    /// On a resumed session, retries setup when the dropped session had not completed it, or when the module has no
    /// identity, as on a new module whose store holds none.
    internal func retrySetupOnResume(accountID: UUID) async {
        guard let client = accountService?.connectedClient(for: accountID), let module = await client.module(ofType: OMEMOModule.self),
              setupStates[accountID] != .complete || module.ownDeviceID == nil else { return }
        module.retrySetup()
    }
}
